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
    private let silenceThreshold: TimeInterval = 2.0  // 静默2秒认为说完

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
        print("Spoken: [DEBUG] startRecording called")

        // 重置状态
        audioEngine = AVAudioEngine()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let audioEngine = audioEngine,
              let recognitionRequest = recognitionRequest else {
            print("Spoken: [ERROR] Failed to create audio engine or recognition request")
            isRecording = false
            return
        }
        print("Spoken: [DEBUG] audioEngine and recognitionRequest created")

        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.lastAudioTime = Date()
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

        // 启动静默检测计时器
        lastAudioTime = Date()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSilence(onResult: onResult)
        }

        // 语音识别
        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let error = error {
                print("Spoken: [ERROR] recognitionTask error: \(error)")
                self?.stopRecording()
                return
            }

            if let result = result {
                print("Spoken: [DEBUG] partial result: \(result.bestTranscription.formattedString)")
                if result.isFinal {
                    self?.stopRecording()
                    let transcript = result.bestTranscription.formattedString
                    print("Spoken: [DEBUG] final transcript: \(transcript)")
                    DispatchQueue.main.async {
                        onResult(transcript)
                    }
                }
            }
        }
    }

    private func checkSilence(onResult: @escaping (String) -> Void) {
        guard isRecording,
              let lastTime = lastAudioTime else { return }

        // 如果超过2秒没有音频输入，认为说完了
        if Date().timeIntervalSince(lastTime) > silenceThreshold {
            print("Spoken: [DEBUG] silence detected, stopping recording")
            silenceTimer?.invalidate()
            silenceTimer = nil

            // 手动结束音频，让识别器输出最终结果
            recognitionRequest?.endAudio()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        print("Spoken: [DEBUG] stopRecording called")

        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.stop()
        if let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }
}
