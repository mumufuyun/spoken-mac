import Foundation
import AVFoundation
import Speech
import os
import Combine

enum SpeechRecognitionProvider: String, CaseIterable {
    case local = "本地识别"
    case cloud = "云端识别"
    case auto = "自动选择"
}

final class SpeechService: NSObject, ObservableObject, @unchecked Sendable {
    private final class PermissionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var microphone = false
        private var speech = false

        func setMicrophone(_ value: Bool) {
            lock.lock(); microphone = value; lock.unlock()
        }

        func setSpeech(_ value: Bool) {
            lock.lock(); speech = value; lock.unlock()
        }

        func snapshot() -> (Bool, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (microphone, speech)
        }
    }

    static let shared = SpeechService()
    private static let logger = os.Logger(subsystem: "com.moss.spoken", category: "SpeechService")

    private func logInfo(_ msg: String) {
        Self.logger.info("\(msg, privacy: .public)")
    }

    private func logWarn(_ msg: String) {
        Self.logger.warning("\(msg, privacy: .public)")
    }

    private func logError(_ msg: String) {
        Self.logger.error("\(msg, privacy: .public)")
    }

    private var audioEngine: AVAudioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    private enum RecordingState {
        case idle
        case starting
        case recording
        case stopping
        case cancelled
    }
    private var state: RecordingState = .idle

    private var lastRecognizedText = ""
    private var capturedOnPartial: ((String) -> Void)?
    private var capturedOnFinal: ((String) -> Void)?
    private var capturedOnStartFailure: ((String) -> Void)?
    private let sessionLock = NSLock()
    private var activeSessionID: UUID?
    private var acceptsSessionAudio = false
    private var sessionAudioReceived = false

    private var retryWorkItem: DispatchWorkItem?

    /// 长时间未录音后，强制重建 AVAudioEngine，避免旧实例在闲置后进入“活死人”状态
    private let audioEngineIdleResetSec: TimeInterval = 300.0
    private var lastRecordingEndTime: Date?

    private var currentProvider: SpeechRecognitionProvider = .local
    private var isUsingCloud = false
    var onCloudConnected: (() -> Void)?
    var onCloudConnectionFailed: ((String) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    private func beginSession() -> UUID {
        let id = UUID()
        sessionLock.lock()
        activeSessionID = id
        acceptsSessionAudio = true
        sessionAudioReceived = false
        sessionLock.unlock()
        return id
    }

    private func isActiveSession(_ id: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSessionID == id
    }

    private func currentSessionID() -> UUID? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSessionID
    }

    private func isAcceptingAudio(for id: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSessionID == id && acceptsSessionAudio
    }

    @discardableResult
    private func markAudioReceived(for id: UUID) -> Bool {
        sessionLock.lock()
        let isFirstFrame = activeSessionID == id && !sessionAudioReceived
        if activeSessionID == id { sessionAudioReceived = true }
        sessionLock.unlock()
        if isFirstFrame { PipelineLatencyMetrics.shared.mark(.firstAudioFrame) }
        return isFirstFrame
    }

    private func hasReceivedAudio(for id: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSessionID == id && sessionAudioReceived
    }

    private func resetAudioReceived(for id: UUID) {
        sessionLock.lock()
        if activeSessionID == id { sessionAudioReceived = false }
        sessionLock.unlock()
    }

    private func stopAcceptingAudio(for id: UUID) {
        sessionLock.lock()
        if activeSessionID == id { acceptsSessionAudio = false }
        sessionLock.unlock()
    }

    @discardableResult
    private func invalidateSession(_ id: UUID? = nil) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let id, activeSessionID != id { return false }
        let hadSession = activeSessionID != nil
        activeSessionID = nil
        acceptsSessionAudio = false
        sessionAudioReceived = false
        return hadSession
    }

    private func failStart(_ reason: String, sessionID: UUID) {
        guard invalidateSession(sessionID) else { return }
        cleanupResources()
        state = .idle
        let callback = capturedOnStartFailure
        DispatchQueue.main.async { callback?(reason) }
    }

    // MARK: - 权限检查

    func requestPermissions(completion: @escaping (Bool, Bool) -> Void) {
        let results = PermissionResults()
        let group = DispatchGroup()

        group.enter()
        AVAudioApplication.requestRecordPermission { granted in
            results.setMicrophone(granted)
            group.leave()
        }

        let rawProvider = UserDefaults.standard.string(forKey: "speechRecognitionProvider")
            ?? SpeechRecognitionProvider.local.rawValue
        let provider = SpeechRecognitionProvider(rawValue: rawProvider) ?? .local
        if provider == .cloud {
            // 纯云端识别不依赖 Speech.framework 权限，避免无关授权阻断启动。
            results.setSpeech(true)
        } else {
            group.enter()
            SFSpeechRecognizer.requestAuthorization { status in
                results.setSpeech(status == .authorized)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let (microphone, speech) = results.snapshot()
            completion(microphone, speech)
        }
    }

    // MARK: - 语言设置

    enum Language: String, CaseIterable {
        case chinese = "zh-CN"
        case english = "en-US"
        case japanese = "ja-JP"
        case korean = "ko-KR"

        var displayName: String {
            switch self {
            case .chinese: return "中文"
            case .english: return "English"
            case .japanese: return "日本語"
            case .korean: return "한국어"
            }
        }
    }

    var currentLanguage: Language = .chinese

    func setLanguage(_ language: Language) {
        currentLanguage = language
    }

    // MARK: - 上下文术语增强

    /// 注入 SFSpeechRecognizer 的常用技术术语列表
    /// 帮助提升中英混合语音场景中技术词汇的识别准确率
    private static let techContextualStrings: [String] = [
        "API", "SDK", "GitHub", "Docker", "Kubernetes", "Kafka",
        "React", "Vue", "Angular", "Node.js", "Python", "Java",
        "TypeScript", "JavaScript", "HTML", "CSS", "SQL", "JSON",
        "URL", "HTTP", "HTTPS", "TCP", "IP", "DNS", "CDN",
        "GPU", "CPU", "RAM", "SSD", "USB", "Wi-Fi",
        "AI", "LLM", "NLP", "ML", "DL", "RAG",
        "CI/CD", "DevOps", "MVP", "PRD", "UI", "UX",
        "IDE", "CLI", "SQL", "ORM", "CRM", "ERP",
        "OKR", "KPI", "ROI", "DAU", "MAU", "PV", "UV",
        "SEO", "SEM", "B2B", "B2C", "O2O",
        "bug", "debug", "deploy", "commit", "review", "merge",
        "branch", "PR", "issue", "ticket",
        "iPhone", "iPad", "MacBook", "iOS", "Android",
        "Windows", "Linux", "Ubuntu", "Vim", "VS Code", "Xcode",
        "Chrome", "Safari", "Firefox", "Zoom", "Slack", "Teams",
        "Notion", "Obsidian", "Trello", "Jira", "GitLab",
        "Jenkins", "Prometheus", "Grafana", "Sentry",
        "Stripe", "PayPal", "Twilio", "Mailchimp",
        "Netflix", "Spotify", "YouTube", "TikTok",
        "Tesla", "NIO", "BYD", "CATL",
        "Y Combinator", "a16z", "Sequoia",
    ]

    // MARK: - 状态查询

    private var isRecording: Bool {
        return state == .recording || state == .starting
    }

    private var isStopping: Bool {
        return state == .stopping
    }

    private var isCancelled: Bool {
        return state == .cancelled
    }

    // MARK: - NSException 安全包装

    /// AVAudioEngine 的 installTap/removeTap 可能抛出 ObjC NSException，
    /// Swift 无法捕获 NSException，会导致应用直接崩溃。
    /// 通过 ObjC 运行时机制捕获异常，防止应用崩溃。
    private func safeRemoveTap(onBus bus: AVAudioNodeBus) {
        ObjCExceptionCatcher.catchException {
            self.audioEngine.inputNode.removeTap(onBus: bus)
        }
    }

    private func safeInstallTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) -> Bool {
        let result = ObjCExceptionCatcher.catchException {
            self.audioEngine.inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
        }
        if let error = result {
            logError("installTap threw exception: \(error)")
            return false
        }
        return true
    }

    // MARK: - 资源清理

    private func cleanupResources() {
        // 取消待执行的重试任务
        retryWorkItem?.cancel()
        retryWorkItem = nil

        // 清理识别任务
        recognitionTask?.cancel()
        recognitionTask = nil

        // 清理识别器
        speechRecognizer = nil

        // 清理识别请求
        recognitionRequest = nil

        // 安全清理音频引擎（removeTap 可能抛出 NSException）
        safeRemoveTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()

        isUsingCloud = false
    }

    /// 重建音频引擎，用于长时间不活动后引擎内部状态失效的场景
    private func resetAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        safeRemoveTap(onBus: 0)
        audioEngine.reset()
    }

    /// 彻底重建 AVAudioEngine 实例，解决长时间闲置后 inputNode 失效的问题
    private func rebuildAudioEngine() {
        logInfo("Rebuilding AVAudioEngine instance...")
        safeRemoveTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        logInfo("AVAudioEngine rebuilt")
    }

    /// 检查音频引擎是否健康（inputNode 格式有效）
    private func isAudioEngineHealthy() -> Bool {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        let healthy = format.sampleRate > 0 && format.channelCount > 0
        logInfo("Audio engine health check: sampleRate=\(format.sampleRate), channels=\(format.channelCount), healthy=\(healthy)")
        return healthy
    }

    // MARK: - 开始录音

    func startRecording(
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onStartFailure: @escaping (String) -> Void = { _ in }
    ) -> Bool {
        guard state == .idle else {
            logWarn("startRecording ignored, state is \(String(describing: self.state))")
            return false
        }

        // 长时间闲置后音频引擎可能失效，先检查健康状态
        if !isAudioEngineHealthy() {
            logWarn("Audio engine unhealthy after idle, rebuilding...")
            rebuildAudioEngine()
        } else if let lastEnd = lastRecordingEndTime,
                  Date().timeIntervalSince(lastEnd) > audioEngineIdleResetSec {
            logWarn("Audio engine idle for \(Int(Date().timeIntervalSince(lastEnd)))s, forcing rebuild...")
            rebuildAudioEngine()
        }

        let rawValue = UserDefaults.standard.string(forKey: "speechRecognitionProvider") ?? SpeechRecognitionProvider.local.rawValue
        let provider = SpeechRecognitionProvider(rawValue: rawValue) ?? .local
        currentProvider = provider
        let sessionID = beginSession()
        capturedOnStartFailure = onStartFailure
        logInfo("startRecording, provider=\(provider.rawValue)")

        switch provider {
        case .local:
            installTapAndStart(onPartial: onPartial, onFinal: onFinal, sessionID: sessionID)
        case .cloud:
            startCloudRecording(onPartial: onPartial, onFinal: onFinal, sessionID: sessionID)
        case .auto:
            startCloudRecording(onPartial: onPartial, onFinal: onFinal, allowFallback: true, sessionID: sessionID)
        }

        return true
    }

    func prepareCloudConnection() {
        let rawValue = UserDefaults.standard.string(forKey: "speechRecognitionProvider") ?? SpeechRecognitionProvider.local.rawValue
        let provider = SpeechRecognitionProvider(rawValue: rawValue) ?? .local
        guard provider == .cloud || provider == .auto else {
            logInfo("prepareCloudConnection skipped, provider=\(provider.rawValue)")
            return
        }
        logInfo("prepareCloudConnection called")
        CloudSpeechService.shared.preconnect()
    }

    // MARK: - 云端识别

    private func startCloudRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, allowFallback: Bool = false, sessionID: UUID) {
        logInfo("startCloudRecording called, allowFallback=\(allowFallback)")
        resetAudioEngine()

        resetAudioReceived(for: sessionID)
        state = .starting
        lastRecognizedText = ""
        capturedOnPartial = onPartial
        capturedOnFinal = onFinal
        isUsingCloud = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        logInfo("cloud inputNode format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            logError("Invalid input format, audio input unavailable")
            if allowFallback {
                logInfo("auto fallback to local")
                currentProvider = .local
                installTapAndStart(onPartial: onPartial, onFinal: onFinal, sessionID: sessionID)
            } else {
                failStart("音频输入不可用", sessionID: sessionID)
            }
            return
        }

        // 先创建云端逻辑会话，再启动音频引擎。这样 tap 收到的第一帧就能进入
        // Provider 的本地缓存，不依赖 WebSocket 是否已经完成握手。
        CloudSpeechService.shared.onConnected = { [weak self] in
            guard let self, self.isActiveSession(sessionID) else { return }
            self.logInfo("CloudSpeechService session ready")
            DispatchQueue.main.async { self.onCloudConnected?() }
        }

        cancellables.removeAll()
        CloudSpeechService.shared.$connectionState
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self, self.isActiveSession(sessionID) else { return }
                if case .failed(let reason) = state {
                    self.logWarn("Cloud connection failed: \(reason)")
                    self.onCloudConnectionFailed?(reason)
                }
            }
            .store(in: &cancellables)

        let modelName = UserDefaults.standard.string(forKey: "speech_model_name") ?? "qwen3-asr-flash-realtime"
        CloudSpeechService.shared.connect(
            model: modelName,
            onPartial: { [weak self] text in
                guard let self, self.isActiveSession(sessionID) else { return }
                self.lastRecognizedText = text
                DispatchQueue.main.async { self.capturedOnPartial?(text) }
            },
            onFinal: { [weak self] text in
                guard let self, self.isActiveSession(sessionID) else { return }
                self.lastRecognizedText = SpeechPostProcessor.postProcess(text)
            },
            onError: { [weak self] error in
                guard let self, self.isActiveSession(sessionID) else { return }
                self.logError("Cloud speech failed after retries: \(error.localizedDescription)")
                DispatchQueue.main.async { self.onCloudConnectionFailed?(error.localizedDescription) }
                // Provider 已经用完重试机会，同时清掉调度层持有的旧会话，
                // 避免下一次录音误用失效连接。
                CloudSpeechService.shared.disconnect()
                if allowFallback && self.state != .stopping && self.state != .cancelled {
                    ASRStabilityMetrics.shared.recordLocalFallback()
                    self.cleanupResources()
                    self.currentProvider = .local
                    self.installTapAndStart(onPartial: onPartial, onFinal: onFinal, sessionID: sessionID)
                } else if self.state != .stopping {
                    self.failStart(error.localizedDescription, sessionID: sessionID)
                }
            }
        )

        let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true)
        var tapFormat: AVAudioFormat? = speechFormat
        var tapInstalled = safeInstallTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self, self.isAcceptingAudio(for: sessionID) else { return }
            self.markAudioReceived(for: sessionID)
            guard self.isUsingCloud else { return }

            guard let pcmData = StreamingASRPCMConverter.data(fromCanonicalBuffer: buffer) else { return }
            CloudSpeechService.shared.sendAudio(pcmData)
        }

        if !tapInstalled, speechFormat != nil {
            logWarn("cloud installTap with 16kHz format failed, converting hardware format explicitly")
            tapFormat = nil
            if let converter = StreamingASRPCMConverter(inputFormat: recordingFormat) {
                tapInstalled = safeInstallTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                    guard let self = self, self.isAcceptingAudio(for: sessionID) else { return }
                    self.markAudioReceived(for: sessionID)
                    guard self.isUsingCloud, let pcmData = converter.convert(buffer) else { return }
                    CloudSpeechService.shared.sendAudio(pcmData)
                }
            } else {
                tapInstalled = false
            }
        }

        logInfo("Cloud tap installed with format: \(tapFormat == nil ? "hardware native" : "16kHz/mono/Int16"), success: \(tapInstalled)")

        if !tapInstalled {
            logError("Failed to install cloud tap on audio engine")
            CloudSpeechService.shared.disconnect()
            if allowFallback {
                logInfo("auto fallback to local")
                currentProvider = .local
                installTapAndStart(onPartial: onPartial, onFinal: onFinal, sessionID: sessionID)
            } else {
                failStart("无法安装云端录音通道", sessionID: sessionID)
            }
            return
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            logInfo("audioEngine started")
            PipelineLatencyMetrics.shared.mark(.audioEngineStarted)
        } catch {
            logError("Audio engine failed to start: \(error)")
            CloudSpeechService.shared.disconnect()
            if allowFallback {
                logInfo("auto fallback to local")
                currentProvider = .local
                installTapAndStart(onPartial: onPartial, onFinal: onFinal, sessionID: sessionID)
            } else {
                failStart("音频引擎启动失败", sessionID: sessionID)
            }
            return
        }

        state = .recording
        logInfo("state changed to recording")

    }

    private func installTapAndStart(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, sessionID: UUID) {
        let maxRetries = 3
        let retryDelays: [TimeInterval] = [0.2, 0.5, 1.0]

        func attemptStart(retryCount: Int) {
            guard isActiveSession(sessionID) else { return }
            guard retryCount < maxRetries else {
                logError("Failed to start recording after \(maxRetries) retries")
                failStart("录音通道启动失败，请重试", sessionID: sessionID)
                return
            }

            // 完整清理上一次尝试，避免旧 recognitionTask 的迟到回调污染新会话。
            cleanupResources()

            // 长时间闲置后引擎可能已失效，若健康检查仍失败则彻底重建
            if !isAudioEngineHealthy() {
                logWarn("Audio engine still unhealthy after reset, rebuilding instance (attempt \(retryCount + 1))")
                rebuildAudioEngine()
            }

            // 重置状态
            resetAudioReceived(for: sessionID)
            state = .starting
            lastRecognizedText = ""
            capturedOnPartial = onPartial
            capturedOnFinal = onFinal

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            logInfo("inputNode format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                logError("Invalid input format, audio input unavailable")
                failStart("音频输入不可用", sessionID: sessionID)
                return
            }

            let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = false
            recognitionRequest.contextualStrings = Self.techContextualStrings
            self.recognitionRequest = recognitionRequest

            // 优先使用 SFSpeechRecognizer 最可靠的 16kHz/mono/Int16 格式
            // 如果格式转换器失败（某些硬件），降级到硬件原生格式（format: nil）
            let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000,
                                              channels: 1,
                                              interleaved: true)
            var tapFormat: AVAudioFormat? = speechFormat
            var tapInstalled = safeInstallTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
                guard let self = self, self.isAcceptingAudio(for: sessionID) else { return }
                recognitionRequest.append(buffer)
                self.markAudioReceived(for: sessionID)
            }

            if !tapInstalled, speechFormat != nil {
                logWarn("installTap with 16kHz format failed, falling back to hardware native format")
                tapFormat = nil
                tapInstalled = safeInstallTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                    guard let self = self, self.isAcceptingAudio(for: sessionID) else { return }
                    recognitionRequest.append(buffer)
                    self.markAudioReceived(for: sessionID)
                }
            }

            logInfo("Tap installed with format: \(tapFormat == nil ? "hardware native" : "16kHz/mono/Int16"), success: \(tapInstalled)")

            if !tapInstalled {
                logError("Failed to install tap on audio engine (attempt \(retryCount + 1))")
                // tap 安装失败，尝试重试
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    attemptStart(retryCount: retryCount + 1)
                }
                return
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
                PipelineLatencyMetrics.shared.mark(.audioEngineStarted)
            } catch {
                logError("Audio engine failed to start: \(error)")
                failStart("音频引擎启动失败", sessionID: sessionID)
                return
            }

            self.state = .recording

            let locale = Locale(identifier: self.currentLanguage.rawValue)
            guard let speechRecognizer = SFSpeechRecognizer(locale: locale) else {
                logError("Failed to create speech recognizer for locale: \(self.currentLanguage.rawValue)")
                self.failStart("无法创建本地语音识别器", sessionID: sessionID)
                return
            }
            self.speechRecognizer = speechRecognizer

            guard speechRecognizer.isAvailable else {
                logError("Speech recognizer not available for locale: \(self.currentLanguage.rawValue)")
                self.failStart("本地语音识别暂不可用", sessionID: sessionID)
                return
            }

            logInfo("Speech recognizer created and available for \(self.currentLanguage.rawValue), starting recognition task")

            self.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    self?.handleLocalRecognition(result: result, error: error, sessionID: sessionID)
                }
            }

            // 检测 tap 是否正常工作（递增重试间隔）
            let delay = retryDelays[min(retryCount, retryDelays.count - 1)]
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isActiveSession(sessionID) else { return }
                if self.state == .recording && !self.hasReceivedAudio(for: sessionID) {
                    logWarn("Tap not receiving audio after \(Int(delay * 1000))ms, retrying (attempt \(retryCount + 1))")
                    attemptStart(retryCount: retryCount + 1)
                }
            }
            self.retryWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        // 开始第一次尝试
        attemptStart(retryCount: 0)
    }

    private func handleLocalRecognition(result: SFSpeechRecognitionResult?, error: Error?, sessionID: UUID) {
        guard isActiveSession(sessionID) else { return }
        if let error {
            let desc = error.localizedDescription.lowercased()
            if desc.contains("cancel") || desc.contains("end") {
                logInfo("recognitionTask ended: \(error.localizedDescription)")
                return
            }
            if desc.contains("no speech") {
                logWarn("recognitionTask: no speech detected - \(error.localizedDescription)")
                return
            }
            logError("recognitionTask error: \(error.localizedDescription)")
            return
        }

        guard let result else {
            logWarn("recognitionTask callback with nil result and nil error")
            return
        }

        let text = result.bestTranscription.formattedString
        if !text.isEmpty {
            lastRecognizedText = text
            logInfo("partial result length=\(text.count)")
            PipelineLatencyMetrics.shared.mark(.firstASRPartial)
            capturedOnPartial?(text)
        }
        if result.isFinal {
            let processedText = SpeechPostProcessor.postProcess(text)
            logInfo("final result length=\(processedText.count)")
            stopAndFinish(lastText: processedText)
        }
    }

    // MARK: - 停止录音

    /// 正常停止录音（静音触发或用户主动停止），会触发 onFinal 回调
    private func stopAndFinish(lastText: String) {
        guard state == .recording else { return }
        guard !isStopping else { return }
        guard let sessionID = currentSessionID() else { return }
        PipelineLatencyMetrics.shared.mark(.stopRequested)
        stopAcceptingAudio(for: sessionID)
        state = .stopping

        if isUsingCloud {
            // 先停止采集，确保不会在 commit 之后继续追加音频。
            safeRemoveTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
            CloudSpeechService.shared.finish { [weak self] cloudText in
                guard let self, self.isActiveSession(sessionID), self.state == .stopping else { return }
                let bestText = CloudRecognitionResultResolver.best(
                    cloudText: cloudText,
                    latestPartial: lastText
                )
                self.completeStoppedRecording(text: bestText)
            }
            return
        }

        cleanupResources()
        completeStoppedRecording(text: lastText)
    }

    private func completeStoppedRecording(text: String) {
        let processed = SpeechPostProcessor.postProcess(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        logInfo("stopAndFinish: finalTextLength=\(processed.count)")
        PipelineLatencyMetrics.shared.mark(.asrFinal)
        cleanupResources()
        state = .idle
        lastRecordingEndTime = Date()
        let callback = capturedOnFinal
        invalidateSession()
        callback?(processed)
    }

    /// 取消录音（用户主动取消），不触发 onFinal 回调
    func cancelRecording() {
        guard state == .recording || state == .starting || state == .stopping else {
            invalidateSession()
            state = .idle
            return
        }

        if isUsingCloud {
            CloudSpeechService.shared.disconnect()
        }

        invalidateSession()
        cleanupResources()
        state = .idle
        lastRecordingEndTime = Date()

        logInfo("recording cancelled")
    }

    /// 用户手动停止录音（停止并返回当前识别结果，触发 onFinal）
    func stopRecording() {
        guard state == .recording else { return }
        let text = lastRecognizedText
        logInfo("stopRecording: finalTextLength=\(text.count)")
        stopAndFinish(lastText: text)
    }

    var isCurrentlyCancelled: Bool {
        return isCancelled
    }

    var isCurrentlyRecording: Bool {
        return isRecording
    }
}
