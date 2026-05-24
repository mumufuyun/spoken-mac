import Foundation
import AVFoundation
import Speech

class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

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
            print("Spoken: [ERROR] installTap threw exception: \(error)")
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

    // MARK: - 开始录音

    func startRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) -> Bool {
        guard state == .idle else {
            print("Spoken: [WARN] startRecording ignored, state is \(state)")
            return false
        }

        installTapAndStart(onPartial: onPartial, onFinal: onFinal)
        return true
    }

    private func installTapAndStart(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        let maxRetries = 3
        let retryDelays: [TimeInterval] = [0.2, 0.5, 1.0]

        func attemptStart(retryCount: Int) {
            guard retryCount < maxRetries else {
                print("Spoken: [ERROR] Failed to start recording after \(maxRetries) retries")
                cleanupResources()
                state = .idle
                return
            }

            // 完整清理旧资源并重建音频引擎
            resetAudioEngine()

            // 重置状态
            audioReceived = false
            state = .starting
            lastRecognizedText = ""
            capturedOnPartial = onPartial
            capturedOnFinal = onFinal

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            print("Spoken: [DEBUG] inputNode format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                print("Spoken: [ERROR] Invalid input format, audio input unavailable")
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
                print("Spoken: [WARN] installTap with 16kHz format failed, falling back to hardware native format")
                tapFormat = nil
                tapInstalled = safeInstallTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                    guard let self = self, self.isRecording else { return }
                    recognitionRequest.append(buffer)
                    self.audioReceived = true
                }
            }

            print("Spoken: [DEBUG] Tap installed with format: \(tapFormat == nil ? "hardware native" : "16kHz/mono/Int16"), success: \(tapInstalled)")

            if !tapInstalled {
                print("Spoken: [ERROR] Failed to install tap on audio engine (attempt \(retryCount + 1))")
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
                print("Spoken: [ERROR] Audio engine failed to start: \(error)")
                cleanupResources()
                state = .idle
                return
            }

            // 给系统时间初始化音频管道
            usleep(200_000)

            self.state = .recording

            let locale = Locale(identifier: self.currentLanguage.rawValue)
            guard let speechRecognizer = SFSpeechRecognizer(locale: locale) else {
                print("Spoken: [ERROR] Failed to create speech recognizer for locale: \(self.currentLanguage.rawValue)")
                self.cleanupResources()
                self.state = .idle
                return
            }
            self.speechRecognizer = speechRecognizer

            guard speechRecognizer.isAvailable else {
                print("Spoken: [ERROR] Speech recognizer not available for locale: \(self.currentLanguage.rawValue)")
                self.cleanupResources()
                self.state = .idle
                return
            }

            print("Spoken: [DEBUG] Speech recognizer created and available for \(self.currentLanguage.rawValue), starting recognition task")

            self.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                if let error = error {
                    let desc = error.localizedDescription.lowercased()
                    if desc.contains("cancel") || desc.contains("end") {
                        print("Spoken: [DEBUG] recognitionTask ended: \(error.localizedDescription)")
                        return
                    }
                    if desc.contains("no speech") {
                        print("Spoken: [WARN] recognitionTask: no speech detected - \(error.localizedDescription)")
                        return
                    }
                    print("Spoken: [ERROR] recognitionTask error: \(error.localizedDescription)")
                    return
                }

                guard let result = result else {
                    print("Spoken: [WARN] recognitionTask callback with nil result and nil error")
                    return
                }

                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    self.lastRecognizedText = text
                    print("Spoken: [DEBUG] partial result: \(text)")
                    DispatchQueue.main.async { self.capturedOnPartial?(text) }
                }

                if result.isFinal {
                    let processedText = SpeechPostProcessor.postProcess(text)
                    if processedText != text {
                        print("Spoken: [DEBUG] post-processed: '\(text)' → '\(processedText)'")
                    }
                    print("Spoken: [DEBUG] final result: \(processedText)")
                    self.stopAndFinish(lastText: processedText)
                }
            }

            // 检测 tap 是否正常工作（递增重试间隔）
            let delay = retryDelays[min(retryCount, retryDelays.count - 1)]
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.state == .recording && !self.audioReceived {
                    print("Spoken: [WARN] Tap not receiving audio after \(Int(delay * 1000))ms, retrying (attempt \(retryCount + 1))")
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

        cleanupResources()

        usleep(stopBufferMs)

        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Spoken: [DEBUG] stopAndFinish: finalText='\(text)'")

        state = .idle
        capturedOnFinal?(text)
    }

    /// 取消录音（用户主动取消），不触发 onFinal 回调
    func cancelRecording() {
        guard state == .recording || state == .starting else {
            state = .idle
            return
        }

        cleanupResources()
        state = .idle

        print("Spoken: [DEBUG] recording cancelled")
    }

    /// 用户手动停止录音（停止并返回当前识别结果，触发 onFinal）
    func stopRecording() {
        guard state == .recording else { return }
        let text = lastRecognizedText
        print("Spoken: [DEBUG] stopRecording: finalText='\(text)'")
        stopAndFinish(lastText: text)
    }

    var isCurrentlyCancelled: Bool {
        return isCancelled
    }

    var isCurrentlyRecording: Bool {
        return isRecording
    }
}


