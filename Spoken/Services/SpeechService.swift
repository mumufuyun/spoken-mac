import Foundation
import AVFoundation
import Speech

class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var isRecording = false
    private var silenceTimer: Timer?
    private var lastSpeechTime = Date()
    private var endTriggered = false
    private var lastRecognizedText = ""
    private var audioReceived = false
    private var timeoutTimer: Timer?

    private var capturedOnPartial: ((String) -> Void)?
    private var capturedOnFinal: ((String) -> Void)?

    private let silenceThreshold: TimeInterval = 3.0
    private let stopBufferMs: UInt32 = 200_000

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

    // MARK: - 开始录音

    func startRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !isRecording else { return }

        // 30 秒超时：超时后自动停止并返回当前识别结果
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording, !self.isCancelled else { return }
            print("Spoken: [WARN] Recording timeout at 30s, stopping with current text")
            let text = self.lastRecognizedText
            self.cancelRecording()
            self.capturedOnPartial?("")
            onFinal(text)
        }

        installTapAndStart(onPartial: onPartial, onFinal: onFinal, retryCount: 0)
    }

    private func installTapAndStart(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, retryCount: Int) {
        guard retryCount < 3 else {
            print("Spoken: [ERROR] Failed to start recording after 3 retries")
            return
        }
        
        // 清理上次状态（必须在最前面，防止旧定时器干扰新录音）
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        
        usleep(100_000)

        audioReceived = false
        isRecording = true
        endTriggered = false
        lastRecognizedText = ""
        lastSpeechTime = Date()
        capturedOnPartial = onPartial
        capturedOnFinal = onFinal

        let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true)!

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        self.recognitionRequest = recognitionRequest

        let inputNode = audioEngine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: speechFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            recognitionRequest.append(buffer)
            self.lastSpeechTime = Date()
            self.audioReceived = true
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Spoken: [ERROR] Audio engine failed to start: \(error)")
            isRecording = false
            return
        }

        // 给系统时间初始化音频管道
        usleep(200_000)

        let locale = Locale(identifier: currentLanguage.rawValue)
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale) else {
            print("Spoken: [ERROR] Failed to create speech recognizer for locale: \(currentLanguage.rawValue)")
            isRecording = false
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                let desc = error.localizedDescription.lowercased()
                if desc.contains("cancel") || desc.contains("end") || desc.contains("no speech") {
                    return
                }
                print("Spoken: [ERROR] recognitionTask error: \(error.localizedDescription)")
                return
            }

            guard let result = result else { return }

            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                self.lastRecognizedText = text
                print("Spoken: [DEBUG] partial result: \(text)")
                DispatchQueue.main.async { self.capturedOnPartial?(text) }
            }

            if result.isFinal {
                print("Spoken: [DEBUG] final result: \(text)")
                self.stopAndFinish(lastText: text)
            }
        }

        // 检测 tap 是否正常工作（递增重试间隔）
        let retryDelays: [UInt32] = [200_000, 500_000, 1_000_000]
        let delay = retryDelays[min(retryCount, retryDelays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(delay) / 1_000_000) { [weak self] in
            guard let self = self else { return }
            if self.isRecording && !self.audioReceived {
                print("Spoken: [WARN] Tap not receiving audio after \(delay/1000)ms, retrying (attempt \(retryCount + 1))")
                self.isRecording = false
                self.audioEngine.inputNode.removeTap(onBus: 0)
                if self.audioEngine.isRunning {
                    self.audioEngine.stop()
                }
                // 不取消 silenceTimer，留给下一次 installTapAndStart 处理
                self.installTapAndStart(onPartial: onPartial, onFinal: onFinal, retryCount: retryCount + 1)
            }
        }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    // MARK: - 静音检测

    private func checkSilence() {
        guard isRecording else { return }
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
        if silenceDuration > silenceThreshold {
            print("Spoken: [DEBUG] silence threshold reached after \(silenceDuration)s")
            stopAndFinish(lastText: lastRecognizedText)
        }
    }

    private var isStopping = false
    private var isCancelled = false

    // MARK: - 停止录音

    /// 正常停止录音（静音触发或用户主动停止），会触发 onFinal 回调
    private func stopAndFinish(lastText: String) {
        guard !endTriggered else { return }
        guard !isStopping else { return }
        isStopping = true
        endTriggered = true

        timeoutTimer?.invalidate()
        timeoutTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        isRecording = false
        isCancelled = false

        usleep(stopBufferMs)

        recognitionTask?.finish()
        recognitionTask = nil

        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Spoken: [DEBUG] stopAndFinish: finalText='\(text)'")

        isStopping = false
        capturedOnFinal?(text)
    }

    /// 取消录音（用户主动取消），不触发 onFinal 回调
    func cancelRecording() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        
        guard isRecording, !endTriggered else {
            isCancelled = true
            return
        }
        isCancelled = true
        endTriggered = true

        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        isRecording = false

        recognitionTask?.cancel()
        recognitionTask = nil

        print("Spoken: [DEBUG] recording cancelled")
    }

    /// 用户手动停止录音（停止并返回当前识别结果，触发 onFinal）
    func stopRecording() {
        guard isRecording, !endTriggered else { return }
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
