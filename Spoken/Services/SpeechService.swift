import Foundation
import AVFoundation
import Speech

class SpeechService: ObservableObject {
    static let shared = SpeechService()

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    private var silenceTimer: Timer?
    private var timeoutTimer: Timer?
    private var lastAudioTime = Date()
    private var endTriggered = false  // 确保 endAudio 只触发一次
    private var lastRecognizedText = ""  // 每次 partial 结果时更新

    private let silenceThreshold: TimeInterval = 2.0

    private init() {}

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

    // MARK: - 录音

    func startRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        endTriggered = false
        lastRecognizedText = ""
        lastAudioTime = Date()
        print("Spoken: [DEBUG] startRecording called")

        audioEngine = AVAudioEngine()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let audioEngine = audioEngine,
              let recognitionRequest = recognitionRequest else {
            print("Spoken: [ERROR] Failed to create audio engine or recognition request")
            isRecording = false
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("Spoken: [DEBUG] inputFormat: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

        // tap 直接写给 recognitionRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            self.recognitionRequest?.append(buffer)
            self.lastAudioTime = Date()
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            print("Spoken: [DEBUG] audioEngine started")
        } catch {
            print("Spoken: [ERROR] Audio engine failed to start: \(error)")
            isRecording = false
            return
        }

        lastAudioTime = Date()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSilence(onPartial: onPartial, onFinal: onFinal)
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            print("Spoken: [DEBUG] timeout")
            self.finishSilently(onPartial: onPartial, onFinal: onFinal)
        }

        // Capture closures to avoid reference cycle
        let capturedOnPartial = onPartial
        let capturedOnFinal = onFinal

        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                let desc = error.localizedDescription.lowercased()
                if desc.contains("cancel") || desc.contains("end") {
                    return
                }
                print("Spoken: [ERROR] recognitionTask error: \(error.localizedDescription)")
                return
            }

            if let result = result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    self.lastRecognizedText = text
                    DispatchQueue.main.async { capturedOnPartial(text) }
                }
                print("Spoken: [DEBUG] partial result: \(text)")

                if result.isFinal {
                    let transcript = text
                    print("Spoken: [DEBUG] isFinal transcript: \(transcript)")
                    // 优先用 isFinal 的结果
                    self.finishWithFinal(transcript: transcript, onPartial: capturedOnPartial, onFinal: capturedOnFinal)
                }
            }
        }
    }

    private func checkSilence(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard isRecording else { return }
        if Date().timeIntervalSince(lastAudioTime) > silenceThreshold {
            print("Spoken: [DEBUG] silence threshold reached")
            finishSilently(onPartial: onPartial, onFinal: onFinal)
        }
    }

    /// silence 超时触发：直接 capture 最后一个 partial 作为最终结果
    /// 防止 isFinal 永远等不到导致的死锁
    private func finishSilently(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !endTriggered else { return }
        endTriggered = true

        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        let finalText = lastRecognizedText
        print("Spoken: [DEBUG] finishSilently: finalText='\(finalText)'")

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        audioEngine = nil

        DispatchQueue.main.async {
            print("Spoken: [DEBUG] finishSilently calling onFinal with: '\(finalText)'")
            onFinal(finalText)
        }
    }

    /// isFinal 到达：优先用 recognizer 的最终结果
    private func finishWithFinal(transcript: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !endTriggered else { return }
        endTriggered = true

        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        print("Spoken: [DEBUG] finishWithFinal: transcript='\(transcript)'")

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        // 不 cancel，直接等 task 自然结束
        isRecording = false
        audioEngine = nil

        DispatchQueue.main.async {
            print("Spoken: [DEBUG] finishWithFinal calling onFinal with: '\(transcript)'")
            onFinal(transcript)
        }
    }

    // 旧版兼容性方法（不推荐使用，但为了保持代码兼容性）
    func stopRecording() {
        guard isRecording, !endTriggered else { return }
        endTriggered = true
        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        audioEngine = nil
    }
    
    /// 新版 stopRecording，需要传入 onFinal 回调
    func stopRecording(onPartial: @escaping (String) -> Void = { _ in }, onFinal: @escaping (String) -> Void = { _ in }) {
        guard isRecording, !endTriggered else { return }
        endTriggered = true
        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        // 保存最后一个识别到的文字
        let finalText = lastRecognizedText
        print("Spoken: [DEBUG] stopRecording: finalText='\(finalText)'")

        // 停止音频引擎和识别任务
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        audioEngine = nil

        // 立即调用 onFinal，没有延迟
        DispatchQueue.main.async {
            print("Spoken: [DEBUG] stopRecording calling onFinal with: '\(finalText)'")
            onFinal(finalText)
        }
    }
}
