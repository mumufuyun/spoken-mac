import Foundation
import AVFoundation

/// Whisper 语音识别服务
/// 架构：AVAudioEngine 录音 → ffmpeg 转 WAV → whisper CLI 识别 → 文本
class WhisperService: ObservableObject {
    static let shared = WhisperService()

    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var silenceTimer: Timer?
    private var lastAudioTime = Date()
    private var tempPCMURL: URL?
    private var tempWAVURL: URL?
    private var audioFile: AVAudioFile?
    private var partialResult = ""

    /// 模型大小: tiny / base / small / medium
    private let modelSize = "small"
    /// openai-whisper .pt 模型目录
    private let modelDir = "/Users/vincent/.cache/whisper"
    /// 语言
    private let language = "zh"
    /// 静默阈值（秒）
    private let silenceThreshold: TimeInterval = 2.0

    private init() {}

    // MARK: - 权限检查

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - 录音开始

    func startRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        partialResult = ""
        lastAudioTime = Date()

        // 创建临时文件
        let tempDir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        tempPCMURL = tempDir.appendingPathComponent("whisper_\(id).pcm")
        tempWAVURL = tempDir.appendingPathComponent("whisper_\(id).wav")

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine,
              let inputNode = audioEngine.inputNode as AVAudioInputNode?,
              tempPCMURL != nil else {
            print("WhisperService: [ERROR] setup failed")
            isRecording = false
            return
        }

        let format = inputNode.outputFormat(forBus: 0)
        print("WhisperService: [DEBUG] input format: \(format)")

        // 创建 PCM 文件（raw 16bit mono）
        guard let pcmURL = tempPCMURL else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            // 删除已存在的文件
            try? FileManager.default.removeItem(at: pcmURL)
            FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
            audioFile = try AVAudioFile(
                forWriting: pcmURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            print("WhisperService: [ERROR] create audio file failed: \(error)")
            isRecording = false
            return
        }

        // 写入录音数据
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            do {
                // 转为单声道 16bit
                let monoBuffer = self.convertToMono16Bit(buffer: buffer)
                try self.audioFile?.write(from: monoBuffer)
            } catch {
                print("WhisperService: [ERROR] write buffer failed: \(error)")
            }
            self.lastAudioTime = Date()
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("WhisperService: [DEBUG] recording started")
        } catch {
            print("WhisperService: [ERROR] audioEngine start failed: \(error)")
            isRecording = false
            return
        }

        // 静默检测
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isRecording && Date().timeIntervalSince(self.lastAudioTime) > self.silenceThreshold {
                print("WhisperService: [DEBUG] silence detected, finishing")
                self.finishRecording(onPartial: onPartial, onFinal: onFinal)
            }
        }
    }

    // MARK: - 录音结束

    private func finishRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard isRecording else { return }
        isRecording = false
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        guard let pcmURL = tempPCMURL, let wavURL = tempWAVURL else {
            DispatchQueue.main.async { onFinal("") }
            return
        }

        audioFile = nil

        // ffmpeg 转换 PCM → WAV
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: pcmURL.path),
                  let size = attrs[.size] as? Int64, size > 0 else {
                DispatchQueue.main.async { onFinal("") }
                return
            }

            let converted = self.convertPCMToWAV(pcmURL: pcmURL, wavURL: wavURL)
            guard converted else {
                DispatchQueue.main.async { onFinal("") }
                return
            }

            // whisper 识别
            let text = self.runWhisper(wavURL: wavURL)
            print("WhisperService: [DEBUG] result: \(text)")

            // 清理临时文件
            try? FileManager.default.removeItem(at: pcmURL)
            try? FileManager.default.removeItem(at: wavURL)
            self.tempPCMURL = nil
            self.tempWAVURL = nil

            DispatchQueue.main.async {
                onFinal(text)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioFile = nil
        if let url = tempPCMURL { try? FileManager.default.removeItem(at: url) }
        if let url = tempWAVURL { try? FileManager.default.removeItem(at: url) }
        tempPCMURL = nil
        tempWAVURL = nil
    }

    // MARK: - 音频处理

    private func convertToMono16Bit(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: true
        )!

        let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: buffer.frameLength
        )!
        monoBuffer.frameLength = buffer.frameLength

        let inputData = buffer.floatChannelData![0]
        let outputData = monoBuffer.int16ChannelData![0]
        let frameCount = Int(buffer.frameLength)

        // float → int16
        for i in 0..<frameCount {
            let sample = inputData[i]
            let clamped = max(-1.0, min(1.0, sample))
            outputData[i] = Int16(clamped * 32767.0)
        }

        return monoBuffer
    }

    private func convertPCMToWAV(pcmURL: URL, wavURL: URL) -> Bool {
        let sampleRate = 48000.0
        let channels = 1

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-f", "s16le",       // 输入格式: signed 16bit little endian
            "-ar", "\(Int(sampleRate))",
            "-ac", "\(channels)",
            "-i", pcmURL.path,   // 输入 PCM
            "-y",                // 覆盖输出
            wavURL.path          // 输出 WAV
        ]

        // 丢弃 stderr
        let nullFile = FileHandle.nullDevice
        process.standardOutput = nullFile
        process.standardError = nullFile

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("WhisperService: [ERROR] ffmpeg failed: \(error)")
            return false
        }
    }

    // MARK: - whisper CLI

    private func runWhisper(wavURL: URL) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper")
        process.arguments = [
            "--model", modelSize,
            "--model_dir", modelDir,
            "--language", language,
            "--task", "transcribe",
            "--output_format", "json",
            wavURL.path
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("WhisperService: [ERROR] whisper failed: \(error)")
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            return ""
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
