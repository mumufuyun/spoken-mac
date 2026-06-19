import Foundation
import AVFoundation
import Speech
import os

enum SpeechRecognitionProvider: String, CaseIterable {
    case local = "本地识别"
    case cloud = "云端识别"
    case auto = "自动选择"
}

class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()
    private static let logger = Logger(subsystem: "com.moss.spoken", category: "SpeechService")

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
    private var audioReceived = false

    private var capturedOnPartial: ((String) -> Void)?
    private var capturedOnFinal: ((String) -> Void)?

    private let stopBufferMs: UInt32 = 200_000

    private var retryWorkItem: DispatchWorkItem?

    private var currentProvider: SpeechRecognitionProvider = .local
    private var isUsingCloud = false
    private var cloudFallbackWorkItem: DispatchWorkItem?
    var onCloudConnected: (() -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - 权限检查

    func requestPermissions(completion: @escaping (Bool, Bool) -> Void) {
        var micGranted = false
        var speechGranted = false

        let group = DispatchGroup()

        group.enter()
        AVAudioApplication.requestRecordPermission { granted in
            micGranted = granted
            group.leave()
        }

        group.enter()
        SFSpeechRecognizer.requestAuthorization { status in
            speechGranted = (status == .authorized)
            group.leave()
        }

        group.notify(queue: .main) {
            completion(micGranted, speechGranted)
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
        cloudFallbackWorkItem?.cancel()
        cloudFallbackWorkItem = nil

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
        safeRemoveTap(onBus: 0)
        usleep(100_000) // 等待旧 tap 完全清理
        if audioEngine.isRunning {
            audioEngine.stop()
        }
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
        usleep(200_000) // 给新引擎初始化时间
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

    func startRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) -> Bool {
        guard state == .idle else {
            logWarn("startRecording ignored, state is \(String(describing: self.state))")
            return false
        }

        // 长时间闲置后音频引擎可能失效，先检查健康状态
        if !isAudioEngineHealthy() {
            logWarn("Audio engine unhealthy after idle, rebuilding...")
            rebuildAudioEngine()
        }

        let rawValue = UserDefaults.standard.string(forKey: "speechRecognitionProvider") ?? SpeechRecognitionProvider.local.rawValue
        let provider = SpeechRecognitionProvider(rawValue: rawValue) ?? .local
        currentProvider = provider
        logInfo("startRecording, provider=\(provider.rawValue)")

        switch provider {
        case .local:
            installTapAndStart(onPartial: onPartial, onFinal: onFinal)
        case .cloud:
            startCloudRecording(onPartial: onPartial, onFinal: onFinal)
        case .auto:
            startCloudRecording(onPartial: onPartial, onFinal: onFinal, allowFallback: true)
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

    private func startCloudRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, allowFallback: Bool = false) {
        logInfo("startCloudRecording called, allowFallback=\(allowFallback)")
        resetAudioEngine()

        audioReceived = false
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
                installTapAndStart(onPartial: onPartial, onFinal: onFinal)
            } else {
                cleanupResources()
                state = .idle
            }
            return
        }

        let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true)
        var tapFormat: AVAudioFormat? = speechFormat
        var tapInstalled = safeInstallTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            self.audioReceived = true
            guard self.isUsingCloud else { return }

            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let data = audioBuffer.mData else { return }
            let pcmData = Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
            CloudSpeechService.shared.sendAudio(pcmData)
        }

        if !tapInstalled, speechFormat != nil {
            logWarn("cloud installTap with 16kHz format failed, falling back to hardware native format")
            tapFormat = nil
            tapInstalled = safeInstallTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                guard let self = self, self.isRecording else { return }
                self.audioReceived = true
                guard self.isUsingCloud else { return }

                let audioBuffer = buffer.audioBufferList.pointee.mBuffers
                guard let data = audioBuffer.mData else { return }
                let pcmData = Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
                CloudSpeechService.shared.sendAudio(pcmData)
            }
        }

        logInfo("Cloud tap installed with format: \(tapFormat == nil ? "hardware native" : "16kHz/mono/Int16"), success: \(tapInstalled)")

        if !tapInstalled {
            logError("Failed to install cloud tap on audio engine")
            if allowFallback {
                logInfo("auto fallback to local")
                currentProvider = .local
                installTapAndStart(onPartial: onPartial, onFinal: onFinal)
            } else {
                cleanupResources()
                state = .idle
            }
            return
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            logInfo("audioEngine started")
        } catch {
            logError("Audio engine failed to start: \(error)")
            if allowFallback {
                logInfo("auto fallback to local")
                currentProvider = .local
                installTapAndStart(onPartial: onPartial, onFinal: onFinal)
            } else {
                cleanupResources()
                state = .idle
            }
            return
        }

        usleep(200_000)
        state = .recording
        logInfo("state changed to recording")

        CloudSpeechService.shared.onConnected = { [weak self] in
            self?.logInfo("CloudSpeechService.onConnected triggered")
            DispatchQueue.main.async {
                self?.onCloudConnected?()
            }
        }

        let modelName = UserDefaults.standard.string(forKey: "speech_model_name") ?? "fun-asr-flash-8k-realtime"
        logInfo("connecting to cloud with model=\(modelName)")

        CloudSpeechService.shared.connect(
            model: modelName,
            onPartial: { [weak self] text in
                guard let self = self else { return }
                self.lastRecognizedText = text
                logInfo("cloud onPartial: '\(text)'")
                DispatchQueue.main.async { self.capturedOnPartial?(text) }
            },
            onFinal: { [weak self] text in
                guard let self = self else { return }
                logInfo("cloud onFinal (sentence_end from server, ignored): '\(text)'")
                // 忽略服务端返回的 sentence_end，只更新最后识别文本
                // 用户必须按快捷键才会结束录音
                self.lastRecognizedText = SpeechPostProcessor.postProcess(text)
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                logError("Cloud speech error: \(error)")
                if allowFallback && self.state != .stopping && self.state != .cancelled {
                    logInfo("auto fallback to local due to cloud error")
                    self.cleanupResources()
                    self.currentProvider = .local
                    self.installTapAndStart(onPartial: onPartial, onFinal: onFinal)
                } else {
                    self.cleanupResources()
                    self.state = .idle
                }
            }
        )

        if CloudSpeechService.shared.isWebSocketOpen {
            logInfo("webSocket already open, triggering onConnected")
            CloudSpeechService.shared.onConnected?()
        }
    }

    private func installTapAndStart(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        let maxRetries = 3
        let retryDelays: [TimeInterval] = [0.2, 0.5, 1.0]

        func attemptStart(retryCount: Int) {
            guard retryCount < maxRetries else {
                logError("Failed to start recording after \(maxRetries) retries")
                cleanupResources()
                state = .idle
                return
            }

            // 完整清理旧资源并重建音频引擎
            resetAudioEngine()

            // 长时间闲置后引擎可能已失效，若健康检查仍失败则彻底重建
            if !isAudioEngineHealthy() {
                logWarn("Audio engine still unhealthy after reset, rebuilding instance (attempt \(retryCount + 1))")
                rebuildAudioEngine()
            }

            // 重置状态
            audioReceived = false
            state = .starting
            lastRecognizedText = ""
            capturedOnPartial = onPartial
            capturedOnFinal = onFinal

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            logInfo("inputNode format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                logError("Invalid input format, audio input unavailable")
                cleanupResources()
                state = .idle
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
            var tapInstalled = safeInstallTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                guard let self = self, self.isRecording else { return }
                recognitionRequest.append(buffer)
                self.audioReceived = true
            }

            if !tapInstalled, speechFormat != nil {
                logWarn("installTap with 16kHz format failed, falling back to hardware native format")
                tapFormat = nil
                tapInstalled = safeInstallTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                    guard let self = self, self.isRecording else { return }
                    recognitionRequest.append(buffer)
                    self.audioReceived = true
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
            } catch {
                logError("Audio engine failed to start: \(error)")
                cleanupResources()
                state = .idle
                return
            }

            // 给系统时间初始化音频管道
            usleep(200_000)

            self.state = .recording

            let locale = Locale(identifier: self.currentLanguage.rawValue)
            guard let speechRecognizer = SFSpeechRecognizer(locale: locale) else {
                logError("Failed to create speech recognizer for locale: \(self.currentLanguage.rawValue)")
                self.cleanupResources()
                self.state = .idle
                return
            }
            self.speechRecognizer = speechRecognizer

            guard speechRecognizer.isAvailable else {
                logError("Speech recognizer not available for locale: \(self.currentLanguage.rawValue)")
                self.cleanupResources()
                self.state = .idle
                return
            }

            logInfo("Speech recognizer created and available for \(self.currentLanguage.rawValue), starting recognition task")

            self.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                if let error = error {
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

                guard let result = result else {
                    logWarn("recognitionTask callback with nil result and nil error")
                    return
                }

                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    self.lastRecognizedText = text
                    logInfo("partial result: \(text)")
                    DispatchQueue.main.async { self.capturedOnPartial?(text) }
                }

                if result.isFinal {
                    let processedText = SpeechPostProcessor.postProcess(text)
                    if processedText != text {
                        logInfo("post-processed: '\(text)' → '\(processedText)'")
                    }
                    logInfo("final result: \(processedText)")
                    self.stopAndFinish(lastText: processedText)
                }
            }

            // 检测 tap 是否正常工作（递增重试间隔）
            let delay = retryDelays[min(retryCount, retryDelays.count - 1)]
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.state == .recording && !self.audioReceived {
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

    // MARK: - 停止录音

    /// 正常停止录音（静音触发或用户主动停止），会触发 onFinal 回调
    private func stopAndFinish(lastText: String) {
        guard state == .recording else { return }
        guard !isStopping else { return }
        state = .stopping

        if isUsingCloud {
            CloudSpeechService.shared.finish()
            CloudSpeechService.shared.disconnect()
        }

        cleanupResources()

        usleep(stopBufferMs)

        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        logInfo("stopAndFinish: finalText='\(text)'")

        state = .idle
        capturedOnFinal?(text)
    }

    /// 取消录音（用户主动取消），不触发 onFinal 回调
    func cancelRecording() {
        guard state == .recording || state == .starting else {
            state = .idle
            return
        }

        if isUsingCloud {
            CloudSpeechService.shared.disconnect()
        }

        cleanupResources()
        state = .idle

        logInfo("recording cancelled")
    }

    /// 用户手动停止录音（停止并返回当前识别结果，触发 onFinal）
    func stopRecording() {
        guard state == .recording else { return }
        let text = lastRecognizedText
        logInfo("stopRecording: finalText='\(text)'")
        stopAndFinish(lastText: text)
    }

    var isCurrentlyCancelled: Bool {
        return isCancelled
    }

    var isCurrentlyRecording: Bool {
        return isRecording
    }
}
