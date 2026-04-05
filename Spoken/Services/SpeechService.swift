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
    private var lastAudioTime: Date?
    private var timeoutTimer: Timer?
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

        // tap 直接写给 recognitionRequest，每个 tap 回调都更新时间戳（原版逻辑）
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
            print("Spoken: [DEBUG] timeout, stopping")
            self.stopRecording()
        }

        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self, self.isRecording else { return }

            if let error = error {
                let desc = error.localizedDescription.lowercased()
                // 取消和结束不算致命错误
                if desc.contains("cancel") || desc.contains("end") {
                    return
                }
                print("Spoken: [ERROR] recognitionTask error: \(error.localizedDescription)")
                return
            }

            if let result = result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    // 每次有结果都调用 onPartial
                    DispatchQueue.main.async { onPartial(text) }
                }
                print("Spoken: [DEBUG] partial result: \(text)")

                if result.isFinal {
                    let transcript = text
                    print("Spoken: [DEBUG] final transcript: \(transcript)")
                    self.stopRecording()
                    DispatchQueue.main.async { onFinal(transcript) }
                }
            }
        }
    }

    private func checkSilence(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard isRecording, let lastTime = lastAudioTime else { return }

        if Date().timeIntervalSince(lastTime) > silenceThreshold {
            print("Spoken: [DEBUG] silence detected, stopping recording")
            silenceTimer?.invalidate()
            silenceTimer = nil
            recognitionRequest?.endAudio()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        print("Spoken: [DEBUG] stopRecording called")

        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // 只 endAudio 一次，防止重复调用
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // cancel task 会触发 error callback（isRecording 已为 false，error 会被忽略）
        recognitionTask?.cancel()
        recognitionTask = nil

        audioEngine = nil
    }
}
