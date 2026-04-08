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
    private var endTriggered = false
    private var lastRecognizedText = ""

    /// 回调闭包（避免重复 capture）
    private var capturedOnPartial: ((String) -> Void)?
    private var capturedOnFinal: ((String) -> Void)?

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
        capturedOnPartial = onPartial
        capturedOnFinal = onFinal

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            self.recognitionRequest?.append(buffer)
            self.lastAudioTime = Date()
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            print("Spoken: [ERROR] Audio engine failed to start: \(error)")
            isRecording = false
            return
        }

        lastAudioTime = Date()

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.stopAndFinish(lastText: self?.lastRecognizedText ?? "")
        }

        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                let desc = error.localizedDescription.lowercased()
                // 用户主动停止不报错
                if desc.contains("cancel") || desc.contains("end") { return }
                print("Spoken: [ERROR] recognitionTask error: \(error.localizedDescription)")
                return
            }

            guard let result = result else { return }

            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                self.lastRecognizedText = text
                DispatchQueue.main.async { self.capturedOnPartial?(text) }
            }

            if result.isFinal {
                self.stopAndFinish(lastText: text)
            }
        }
    }

    private func checkSilence() {
        guard isRecording else { return }
        if Date().timeIntervalSince(lastAudioTime) > silenceThreshold {
            print("Spoken: [DEBUG] silence threshold reached")
            stopAndFinish(lastText: lastRecognizedText)
        }
    }

    /// 统一的停止入口，所有停止路径都走这里
    private func stopAndFinish(lastText: String) {
        guard !endTriggered else { return }
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

        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in
            self?.capturedOnFinal?(text)
        }
    }

    // MARK: - 停止录音

    func stopRecording() {
        guard isRecording, !endTriggered else { return }
        stopAndFinish(lastText: lastRecognizedText)
    }
}
