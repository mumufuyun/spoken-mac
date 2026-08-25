import Foundation

struct AudioReplayBuffer {
    let maxBytes: Int
    private(set) var buffers: [Data] = []
    private(set) var byteCount = 0

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffers.append(data)
        byteCount += data.count
        while byteCount > maxBytes, !buffers.isEmpty {
            byteCount -= buffers.removeFirst().count
        }
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        buffers.removeAll(keepingCapacity: keepingCapacity)
        byteCount = 0
    }
}

enum CloudRecognitionResultResolver {
    static func best(cloudText: String?, latestPartial: String) -> String {
        let cloud = cloudText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cloud.isEmpty ? latestPartial : cloud
    }
}

struct WarmConnectionReusePolicy {
    static func canReuse(
        age: TimeInterval,
        maxAge: TimeInterval,
        sameAPIKey: Bool,
        sameModel: Bool,
        hasTransport: Bool,
        hasMissedHeartbeat: Bool
    ) -> Bool {
        return age >= 0
            && age <= maxAge
            && sameAPIKey
            && sameModel
            && hasTransport
            && !hasMissedHeartbeat
    }
}

enum QwenSessionHandshakeAction: Equatable {
    case sendSessionUpdate
    case markReady
    case ignore
}

struct QwenSessionHandshakePolicy {
    static func action(for eventType: String) -> QwenSessionHandshakeAction {
        switch eventType {
        case "session.created": .sendSessionUpdate
        case "session.updated": .markReady
        default: .ignore
        }
    }
}

struct PCMVoiceActivityDetector {
    static func containsMeaningfulSpeech(
        _ data: Data,
        amplitudeThreshold: Int = 700,
        minimumActiveRatio: Double = 0.01
    ) -> Bool {
        guard data.count >= 2 else { return false }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let sampleCount = bytes.count / 2
            let requiredActiveSamples = max(1, Int(ceil(Double(sampleCount) * minimumActiveRatio)))
            var activeSamples = 0
            for index in stride(from: 0, to: sampleCount * 2, by: 2) {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let amplitude = abs(Int(Int16(bitPattern: bits)))
                if amplitude >= amplitudeThreshold {
                    activeSamples += 1
                    if activeSamples >= requiredActiveSamples { return true }
                }
            }
            return false
        }
    }
}

/// 每次录音使用一个独立的逻辑会话。所有状态都在 stateQueue 上修改，避免音频线程、
/// URLSession delegate 和主线程同时改写连接状态。
final class ReliableQwenSpeechProvider: NSObject, CloudSpeechProvider, @unchecked Sendable {
    static let shared = ReliableQwenSpeechProvider()

    let providerId = "qwen-realtime"
    let displayName = "千问云 Realtime"

    private static let logger = UnifiedLogger(
        subsystem: "com.moss.spoken",
        category: "ReliableQwenProvider"
    )

    private let stateQueue = DispatchQueue(label: "com.moss.spoken.qwen-state")
    private let queueKey = DispatchSpecificKey<Void>()

    private var currentSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionID = UUID()
    private var retryCount = 0
    private let maxRetries = 2
    private let retryDelays: [TimeInterval] = [0.3, 0.8]
    private let warmRecoveryDelays: [TimeInterval] = [1, 2, 5, 10, 30]
    private let connectTimeout: TimeInterval = 5
    private let finishTimeout: TimeInterval = 8
    private let warmConnectionMaxAge: TimeInterval = 120
    private let firstTranscriptTimeout: TimeInterval = 3
    private let maxTranscriptRecoveryAttempts = 1

    private var apiKey = ""
    private var model = ""
    private var sessionReady = false
    private var sessionUpdateSent = false
    private var commitSent = false
    private var sessionFinishSent = false
    private var finishRequested = false
    private var intentionallyClosing = false
    private var accumulatedText = ""
    private var eventSequence: UInt64 = 0

    /// 保留整段录音，网络中断时可以在新会话中重放，而不是丢掉断线前的语音。
    // 16 kHz / 16-bit / mono PCM 约为 32 KB/s；64 MiB 可覆盖约 35 分钟音频。
    private var replayBuffer = AudioReplayBuffer(maxBytes: 64 * 1024 * 1024)
    private var pendingAudioBuffers: [Data] = []

    private var connectTimeoutItem: DispatchWorkItem?
    private var finishTimeoutItem: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var missedPongs = 0
    private var warmRecoveryItem: DispatchWorkItem?
    private var warmRecoveryAttempt = 0
    private var connectionStartedAt: TimeInterval?
    private var isWarmTransport = false
    private var hasPublishedFirstPartial = false
    private var hasMeaningfulSpeech = false
    private var transcriptRecoveryAttempts = 0
    private var firstTranscriptTimeoutItem: DispatchWorkItem?

    private var partialCallback: ((String) -> Void)?
    private var finalCallback: ((String) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var finishCompletion: ((String?) -> Void)?
    private var stateCallback: ((CloudConnectionState) -> Void)?
    private var internalConnectionState: CloudConnectionState = .idle

    var connectionState: CloudConnectionState {
        syncState { internalConnectionState }
    }

    var isReady: Bool {
        syncState { sessionReady && webSocketTask != nil }
    }

    var onConnectionStateChanged: ((CloudConnectionState) -> Void)? {
        get { syncState { stateCallback } }
        set { stateQueue.async { self.stateCallback = newValue } }
    }

    private override init() {
        super.init()
        stateQueue.setSpecific(key: queueKey, value: ())
    }

    func connect(
        apiKey: String? = nil,
        model: String = "",
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let resolvedKey = apiKey ?? SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        let resolvedModel = model.isEmpty
            ? (UserDefaults.standard.string(forKey: "speech_model_name") ?? "qwen3-asr-flash-realtime")
            : model

        stateQueue.async {
            guard !resolvedKey.isEmpty else {
                self.updateState(.failed("未配置 API Key"))
                DispatchQueue.main.async { onError(CloudSpeechError.missingAPIKey) }
                return
            }

            if self.canAdoptWarmConnection(apiKey: resolvedKey, model: resolvedModel) {
                self.cancelWarmRecovery()
                self.isWarmTransport = false
                self.partialCallback = onPartial
                self.finalCallback = onFinal
                self.errorCallback = onError
                self.accumulatedText = ""
                self.replayBuffer.removeAll(keepingCapacity: true)
                self.pendingAudioBuffers.removeAll(keepingCapacity: true)
                self.finishRequested = false
                self.commitSent = false
                self.sessionFinishSent = false
                self.hasPublishedFirstPartial = false
                self.hasMeaningfulSpeech = false
                self.transcriptRecoveryAttempts = 0
                self.cancelFirstTranscriptTimeout()
                ASRStabilityMetrics.shared.recordSessionStarted()
                Self.logger.info("session=\(self.shortSessionID) adopted warm connection ready=\(self.sessionReady)")
                if self.sessionReady {
                    ASRStabilityMetrics.shared.recordConnected()
                    PipelineLatencyMetrics.shared.mark(.asrConnected)
                    let callback = self.stateCallback
                    DispatchQueue.main.async { callback?(.connected) }
                }
                return
            }

            self.closeTransport(clearBusinessState: true, notifyDisconnected: false)
            self.sessionID = UUID()
            self.apiKey = resolvedKey
            self.model = resolvedModel
            self.partialCallback = onPartial
            self.finalCallback = onFinal
            self.errorCallback = onError
            self.retryCount = 0
            self.accumulatedText = ""
            self.replayBuffer.removeAll(keepingCapacity: true)
            self.pendingAudioBuffers.removeAll(keepingCapacity: true)
            self.finishRequested = false
            self.commitSent = false
            self.sessionFinishSent = false
            self.intentionallyClosing = false
            self.connectionStartedAt = ProcessInfo.processInfo.systemUptime
            self.isWarmTransport = false
            self.warmRecoveryAttempt = 0
            self.hasPublishedFirstPartial = false
            self.hasMeaningfulSpeech = false
            self.transcriptRecoveryAttempts = 0
            self.cancelFirstTranscriptTimeout()

            Self.logger.info("session=\(self.shortSessionID) starting fresh connection")
            ASRStabilityMetrics.shared.recordSessionStarted()
            self.startConnectionAttempt()
        }
    }

    func preconnect() {
        let resolvedKey = SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        let resolvedModel = UserDefaults.standard.string(forKey: "speech_model_name")
            ?? "qwen3-asr-flash-realtime"
        guard !resolvedKey.isEmpty else { return }

        stateQueue.async {
            if self.canAdoptWarmConnection(apiKey: resolvedKey, model: resolvedModel) {
                Self.logger.info("session=\(self.shortSessionID) preconnect reused persistent warm transport")
                return
            }

            self.closeTransport(clearBusinessState: true, notifyDisconnected: false)
            self.sessionID = UUID()
            self.apiKey = resolvedKey
            self.model = resolvedModel
            self.retryCount = 0
            self.finishRequested = false
            self.commitSent = false
            self.sessionFinishSent = false
            self.intentionallyClosing = false
            self.connectionStartedAt = ProcessInfo.processInfo.systemUptime
            self.isWarmTransport = true
            self.hasPublishedFirstPartial = false
            self.hasMeaningfulSpeech = false
            self.transcriptRecoveryAttempts = 0
            self.cancelFirstTranscriptTimeout()
            self.warmRecoveryAttempt = 0
            Self.logger.info("session=\(self.shortSessionID) starting persistent warm connection")
            self.startConnectionAttempt()
        }
    }

    func cancelPreconnect() {
        stateQueue.async {
            guard self.isWarmTransport else { return }
            self.closeTransport(clearBusinessState: true, notifyDisconnected: false)
            self.updateState(.idle)
        }
    }

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        stateQueue.async {
            guard self.partialCallback != nil else { return }
            self.appendReplayBuffer(data)
            if !self.hasMeaningfulSpeech,
               PCMVoiceActivityDetector.containsMeaningfulSpeech(data) {
                self.hasMeaningfulSpeech = true
                Self.logger.info("session=\(self.shortSessionID) meaningful speech detected")
                self.scheduleFirstTranscriptTimeoutIfNeeded()
            }
            if self.sessionReady, let task = self.webSocketTask {
                self.sendAudioData(data, task: task)
            } else {
                self.pendingAudioBuffers.append(data)
            }
        }
    }

    func finish(completion: @escaping (String?) -> Void) {
        stateQueue.async {
            guard self.partialCallback != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.finishRequested = true
            self.finishCompletion = completion
            self.scheduleFinishTimeout()

            if self.sessionReady {
                self.flushPendingAudioAndCommit()
            } else {
                Self.logger.info("session=\(self.shortSessionID) finish queued until session is ready")
            }
        }
    }

    func disconnect() {
        stateQueue.async {
            self.intentionallyClosing = true
            let completion = self.finishCompletion
            self.finishCompletion = nil
            self.closeTransport(clearBusinessState: true, notifyDisconnected: true)
            if let completion {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - Connection lifecycle

    private func startConnectionAttempt() {
        assertOnStateQueue()
        cancelConnectTimeout()
        cancelFirstTranscriptTimeout()
        stopHeartbeat()
        sessionReady = false
        sessionUpdateSent = false
        commitSent = false
        sessionFinishSent = false
        intentionallyClosing = false

        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=\(model)") else {
            failPermanently(CloudSpeechError.invalidURL)
            return
        }

        updateState(retryCount == 0 ? .connecting : .connecting)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = connectTimeout

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = connectTimeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        currentSession = session
        webSocketTask = task

        Self.logger.info("session=\(shortSessionID) connect attempt=\(retryCount + 1)")
        task.resume()
        scheduleConnectTimeout(for: task)
    }

    private func retryOrFail(_ error: Error, failedTask: URLSessionWebSocketTask?) {
        assertOnStateQueue()
        if let failedTask, webSocketTask !== failedTask { return }
        guard !intentionallyClosing else { return }

        cancelConnectTimeout()
        cancelFirstTranscriptTimeout()
        stopHeartbeat()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        currentSession?.invalidateAndCancel()
        webSocketTask = nil
        currentSession = nil
        sessionReady = false

        guard retryCount < maxRetries else {
            if isWarmTransport && partialCallback == nil {
                scheduleWarmRecovery(after: error)
                return
            }
            failPermanently(error)
            return
        }

        let delay = retryDelays[min(retryCount, retryDelays.count - 1)]
        retryCount += 1
        pendingAudioBuffers = replayBuffer.buffers
        ASRStabilityMetrics.shared.recordReconnect()
        Self.logger.warning(
            "session=\(shortSessionID) reconnecting in \(delay)s, replayBytes=\(replayBuffer.byteCount)"
        )
        let expectedSessionID = sessionID
        stateQueue.asyncAfter(deadline: .now() + delay) {
            guard self.sessionID == expectedSessionID, !self.intentionallyClosing else { return }
            self.startConnectionAttempt()
        }
    }

    private func failPermanently(_ error: Error) {
        assertOnStateQueue()
        updateState(.failed(error.localizedDescription))
        ASRStabilityMetrics.shared.recordCloudFailure()
        let errorCallback = self.errorCallback
        let completion = finishCompletion
        let fallbackText = accumulatedText.nilIfEmpty
        finishCompletion = nil
        closeTransport(clearBusinessState: false, notifyDisconnected: false)
        DispatchQueue.main.async {
            errorCallback?(error)
            completion?(fallbackText)
        }
    }

    private func closeTransport(clearBusinessState: Bool, notifyDisconnected: Bool) {
        assertOnStateQueue()
        cancelConnectTimeout()
        cancelFinishTimeout()
        cancelWarmRecovery()
        cancelFirstTranscriptTimeout()
        stopHeartbeat()

        let task = webSocketTask
        webSocketTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        currentSession?.invalidateAndCancel()
        currentSession = nil
        sessionReady = false
        sessionUpdateSent = false
        commitSent = false
        sessionFinishSent = false

        if clearBusinessState {
            partialCallback = nil
            finalCallback = nil
            errorCallback = nil
            finishCompletion = nil
            replayBuffer.removeAll()
            pendingAudioBuffers.removeAll()
            accumulatedText = ""
            finishRequested = false
            apiKey = ""
            model = ""
            connectionStartedAt = nil
            isWarmTransport = false
            warmRecoveryAttempt = 0
            hasPublishedFirstPartial = false
            hasMeaningfulSpeech = false
            transcriptRecoveryAttempts = 0
        }

        if notifyDisconnected {
            updateState(.disconnected)
        }
    }

    // MARK: - Protocol messages

    private func sendSessionUpdate(task: URLSessionWebSocketTask) {
        assertOnStateQueue()
        guard webSocketTask === task, !sessionUpdateSent else { return }
        sessionUpdateSent = true
        let event: [String: Any] = [
            "event_id": nextEventID(),
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": 16000,
                "input_audio_transcription": ["language": "zh"],
                "turn_detection": NSNull()
            ]
        ]
        sendJSON(event, task: task) { [weak self] error in
            guard let self, let error else { return }
            self.retryOrFail(error, failedTask: task)
        }
    }

    private func sendAudioData(_ data: Data, task: URLSessionWebSocketTask) {
        assertOnStateQueue()
        let event: [String: Any] = [
            "event_id": nextEventID(),
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        sendJSON(event, task: task) { [weak self] error in
            guard let self, let error else { return }
            self.retryOrFail(error, failedTask: task)
        }
    }

    private func flushPendingAudioAndCommit() {
        assertOnStateQueue()
        guard sessionReady, let task = webSocketTask else { return }
        let buffers = pendingAudioBuffers
        pendingAudioBuffers.removeAll(keepingCapacity: true)
        Self.logger.info("session=\(shortSessionID) flushing buffers=\(buffers.count)")
        for buffer in buffers {
            sendAudioData(buffer, task: task)
        }
        sendCommit(task: task)
    }

    private func sendCommit(task: URLSessionWebSocketTask) {
        assertOnStateQueue()
        guard webSocketTask === task, !commitSent else { return }
        commitSent = true
        let event: [String: Any] = [
            "event_id": nextEventID(),
            "type": "input_audio_buffer.commit"
        ]
        Self.logger.info("session=\(shortSessionID) sending commit")
        PipelineLatencyMetrics.shared.mark(.asrCommitSent)
        sendJSON(event, task: task) { [weak self] error in
            guard let self, let error else { return }
            self.retryOrFail(error, failedTask: task)
        }
    }

    private func sendSessionFinish(task: URLSessionWebSocketTask) {
        assertOnStateQueue()
        guard webSocketTask === task, !sessionFinishSent else { return }
        sessionFinishSent = true
        let event: [String: Any] = [
            "event_id": nextEventID(),
            "type": "session.finish"
        ]
        Self.logger.info("session=\(shortSessionID) sending session.finish")
        sendJSON(event, task: task) { [weak self] error in
            guard let self, let error else { return }
            self.retryOrFail(error, failedTask: task)
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        task: URLSessionWebSocketTask,
        completion: @escaping (Error?) -> Void
    ) {
        assertOnStateQueue()
        guard webSocketTask === task else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let string = String(data: data, encoding: .utf8) else {
                completion(CloudSpeechError.connectionFailed)
                return
            }
            task.send(.string(string)) { [weak self] error in
                self?.stateQueue.async { completion(error) }
            }
        } catch {
            completion(error)
        }
    }

    private func receiveNext(task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.stateQueue.async {
                guard self.webSocketTask === task else { return }
                switch result {
                case .failure(let error):
                    self.retryOrFail(error, failedTask: task)
                case .success(let message):
                    self.handleMessage(message, task: task)
                    if self.webSocketTask === task {
                        self.receiveNext(task: task)
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, task: URLSessionWebSocketTask) {
        assertOnStateQueue()
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch QwenSessionHandshakePolicy.action(for: type) {
        case .sendSessionUpdate:
            Self.logger.info("session=\(shortSessionID) session.created; sending session.update")
            sendSessionUpdate(task: task)
            return

        case .markReady:
            sessionReady = true
            cancelConnectTimeout()
            cancelWarmRecovery()
            retryCount = 0
            warmRecoveryAttempt = 0
            updateState(.connected)
            if !isWarmTransport {
                ASRStabilityMetrics.shared.recordConnected()
                PipelineLatencyMetrics.shared.mark(.asrConnected)
            }
            flushPendingAudio()
            scheduleFirstTranscriptTimeoutIfNeeded()
            if finishRequested { sendCommit(task: task) }
            return

        case .ignore:
            break
        }

        switch type {
        case "conversation.item.input_audio_transcription.text":
            let confirmed = json["text"] as? String ?? ""
            let stash = json["stash"] as? String ?? ""
            publishPartial(confirmed + stash)

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                publishPartial(accumulatedText + delta)
            }

        case "conversation.item.input_audio_transcription.completed":
            let transcript = extractTranscript(json) ?? accumulatedText
            if !transcript.isEmpty { publishPartial(transcript) }
            if finishRequested { sendSessionFinish(task: task) }

        case "session.finished":
            if finishRequested { completeSuccessfully(accumulatedText) }

        case "error":
            let payload = json["error"] as? [String: Any]
            let message = payload?["message"] as? String ?? "Unknown API error"
            retryOrFail(CloudSpeechError.apiError(message), failedTask: task)

        default:
            break
        }
    }

    private func flushPendingAudio() {
        assertOnStateQueue()
        guard sessionReady, let task = webSocketTask else { return }
        let buffers = pendingAudioBuffers
        pendingAudioBuffers.removeAll(keepingCapacity: true)
        for buffer in buffers { sendAudioData(buffer, task: task) }
    }

    private func publishPartial(_ text: String) {
        assertOnStateQueue()
        guard !text.isEmpty else { return }
        accumulatedText = text
        if !hasPublishedFirstPartial {
            hasPublishedFirstPartial = true
            cancelFirstTranscriptTimeout()
            PipelineLatencyMetrics.shared.mark(.firstASRPartial)
        }
        let callback = partialCallback
        DispatchQueue.main.async { callback?(text) }
    }

    private func completeSuccessfully(_ text: String, recordAsSuccess: Bool = true) {
        assertOnStateQueue()
        let finalText = text.isEmpty ? accumulatedText : text
        let finalCallback = self.finalCallback
        let completion = finishCompletion
        finishCompletion = nil
        if recordAsSuccess {
            ASRStabilityMetrics.shared.recordCloudSuccess()
        } else {
            ASRStabilityMetrics.shared.recordCloudFailure()
        }
        Self.logger.info("session=\(shortSessionID) completed chars=\(finalText.count)")
        intentionallyClosing = true
        closeTransport(clearBusinessState: true, notifyDisconnected: false)
        updateState(.disconnected)
        DispatchQueue.main.async {
            if !finalText.isEmpty { finalCallback?(finalText) }
            completion?(finalText.nilIfEmpty)
        }
    }

    // MARK: - Timers and heartbeat

    private func scheduleConnectTimeout(for task: URLSessionWebSocketTask) {
        cancelConnectTimeout()
        let item = DispatchWorkItem { [weak self, weak task] in
            guard let self, let task, self.webSocketTask === task, !self.sessionReady else { return }
            self.retryOrFail(CloudSpeechError.timeout, failedTask: task)
        }
        connectTimeoutItem = item
        stateQueue.asyncAfter(deadline: .now() + connectTimeout, execute: item)
    }

    private func cancelConnectTimeout() {
        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil
    }

    private func scheduleFinishTimeout() {
        cancelFinishTimeout()
        let expectedSessionID = sessionID
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == expectedSessionID, self.finishRequested else { return }
            Self.logger.warning("session=\(self.shortSessionID) final timeout, using latest partial")
            self.completeSuccessfully(
                self.accumulatedText,
                recordAsSuccess: !self.accumulatedText.isEmpty
            )
        }
        finishTimeoutItem = item
        stateQueue.asyncAfter(deadline: .now() + finishTimeout, execute: item)
    }

    private func scheduleFirstTranscriptTimeoutIfNeeded() {
        assertOnStateQueue()
        guard sessionReady,
              hasMeaningfulSpeech,
              !hasPublishedFirstPartial,
              !finishRequested,
              partialCallback != nil,
              firstTranscriptTimeoutItem == nil else { return }
        let expectedSessionID = sessionID
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firstTranscriptTimeoutItem = nil
            guard
                  self.sessionID == expectedSessionID,
                  self.sessionReady,
                  self.hasMeaningfulSpeech,
                  !self.hasPublishedFirstPartial,
                  !self.finishRequested,
                  self.partialCallback != nil else { return }
            self.recoverFromTranscriptStall()
        }
        firstTranscriptTimeoutItem = item
        stateQueue.asyncAfter(deadline: .now() + firstTranscriptTimeout, execute: item)
    }

    private func cancelFirstTranscriptTimeout() {
        firstTranscriptTimeoutItem?.cancel()
        firstTranscriptTimeoutItem = nil
    }

    private func recoverFromTranscriptStall() {
        assertOnStateQueue()
        guard transcriptRecoveryAttempts < maxTranscriptRecoveryAttempts else {
            Self.logger.error("session=\(shortSessionID) recognition still stalled after replay recovery")
            failPermanently(CloudSpeechError.recognitionStalled)
            return
        }

        transcriptRecoveryAttempts += 1
        let bufferedAudio = replayBuffer.buffers
        Self.logger.warning(
            "session=\(shortSessionID) no transcript after meaningful speech; reconnecting and replaying bytes=\(replayBuffer.byteCount)"
        )
        ASRStabilityMetrics.shared.recordReconnect()
        closeTransport(clearBusinessState: false, notifyDisconnected: false)
        pendingAudioBuffers = bufferedAudio
        sessionID = UUID()
        retryCount = 0
        intentionallyClosing = false
        connectionStartedAt = ProcessInfo.processInfo.systemUptime
        isWarmTransport = false
        startConnectionAttempt()
    }

    private func cancelFinishTimeout() {
        finishTimeoutItem?.cancel()
        finishTimeoutItem = nil
    }

    private func canAdoptWarmConnection(apiKey: String, model: String) -> Bool {
        assertOnStateQueue()
        guard let connectionStartedAt else { return false }
        let age = ProcessInfo.processInfo.systemUptime - connectionStartedAt
        return isWarmTransport && WarmConnectionReusePolicy.canReuse(
            age: age,
            maxAge: warmConnectionMaxAge,
            sameAPIKey: self.apiKey == apiKey,
            sameModel: self.model == model,
            hasTransport: webSocketTask != nil,
            hasMissedHeartbeat: missedPongs > 0
        )
    }

    private func scheduleWarmRecovery(after error: Error) {
        assertOnStateQueue()
        closeTransport(clearBusinessState: false, notifyDisconnected: false)
        updateState(.failed(error.localizedDescription))

        let delay = warmRecoveryDelays[min(warmRecoveryAttempt, warmRecoveryDelays.count - 1)]
        warmRecoveryAttempt += 1
        let expectedAPIKey = apiKey
        let expectedModel = model
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isWarmTransport,
                  self.partialCallback == nil,
                  self.apiKey == expectedAPIKey,
                  self.model == expectedModel else { return }
            self.sessionID = UUID()
            self.retryCount = 0
            self.connectionStartedAt = ProcessInfo.processInfo.systemUptime
            self.intentionallyClosing = false
            ASRStabilityMetrics.shared.recordReconnect()
            Self.logger.info("session=\(self.shortSessionID) self-healing warm connection attempt=\(self.warmRecoveryAttempt)")
            self.startConnectionAttempt()
        }
        warmRecoveryItem = item
        Self.logger.warning("warm connection unavailable; retrying in \(delay)s")
        stateQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelWarmRecovery() {
        warmRecoveryItem?.cancel()
        warmRecoveryItem = nil
    }

    private func startHeartbeat(task: URLSessionWebSocketTask) {
        stopHeartbeat()
        missedPongs = 0
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task, self.webSocketTask === task else { return }
            task.sendPing { [weak self, weak task] error in
                guard let self, let task else { return }
                self.stateQueue.async {
                    guard self.webSocketTask === task else { return }
                    if let error {
                        self.missedPongs += 1
                        if self.missedPongs >= 2 {
                            self.retryOrFail(error, failedTask: task)
                        }
                    } else {
                        self.missedPongs = 0
                    }
                }
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.setEventHandler {}
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        missedPongs = 0
    }

    // MARK: - Helpers

    private func appendReplayBuffer(_ data: Data) {
        assertOnStateQueue()
        replayBuffer.append(data)
    }

    private func extractTranscript(_ json: [String: Any]) -> String? {
        if let transcript = json["transcript"] as? String { return transcript }
        guard let item = json["item"] as? [String: Any],
              let content = item["content"] as? [[String: Any]] else { return nil }
        return content.first?["transcript"] as? String
    }

    private func nextEventID() -> String {
        eventSequence += 1
        return "event_\(shortSessionID)_\(eventSequence)"
    }

    private var shortSessionID: String {
        String(sessionID.uuidString.prefix(8))
    }

    private func updateState(_ newState: CloudConnectionState) {
        assertOnStateQueue()
        guard internalConnectionState != newState else { return }
        internalConnectionState = newState
        let callback = stateCallback
        DispatchQueue.main.async { callback?(newState) }
    }

    private func syncState<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return stateQueue.sync(execute: body)
    }

    private func assertOnStateQueue() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
    }
}

extension ReliableQwenSpeechProvider: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        stateQueue.async {
            guard self.webSocketTask === webSocketTask else { return }
            Self.logger.info("session=\(self.shortSessionID) websocket opened")
            self.startHeartbeat(task: webSocketTask)
            self.receiveNext(task: webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        stateQueue.async {
            guard self.webSocketTask === webSocketTask else { return }
            if self.intentionallyClosing { return }
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
            let error = CloudSpeechError.apiError("连接关闭(\(closeCode.rawValue)): \(reasonText)")
            self.retryOrFail(error, failedTask: webSocketTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let socketTask = task as? URLSessionWebSocketTask, let error else { return }
        stateQueue.async {
            guard self.webSocketTask === socketTask, !self.intentionallyClosing else { return }
            self.retryOrFail(error, failedTask: socketTask)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
