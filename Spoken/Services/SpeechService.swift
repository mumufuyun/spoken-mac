import Foundation
import AVFoundation
import Speech

class SpeechService: ObservableObject {
    static let shared = SpeechService()

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false

    private init() {}

    // MARK: - 权限检查

    func requestPermissions(completion: @escaping (Bool, Bool) -> Void) {
        var micGranted = false
        var speechGranted = false

        let group = DispatchGroup()

        // 麦克风权限
        group.enter()
        AVAudioApplication.requestRecordPermission { granted in
            micGranted = granted
            group.leave()
        }

        // 语音识别权限
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

    func startRecording(onResult: @escaping (String) -> Void) {
        guard !isRecording else { return }
        isRecording = true

        // 重置状态
        audioEngine = AVAudioEngine()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let audioEngine = audioEngine,
              let recognitionRequest = recognitionRequest else {
            print("Spoken: Failed to create audio engine or recognition request")
            isRecording = false
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            print("Spoken: Audio engine failed to start: \(error)")
            isRecording = false
            return
        }

        // 语音识别
        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                if result.isFinal {
                    self?.stopRecording()
                    DispatchQueue.main.async {
                        onResult(transcript)
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                self?.stopRecording()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }
}
