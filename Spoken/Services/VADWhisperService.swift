import Foundation
import AVFoundation

/// VAD + faster-whisper 流式识别服务
/// 架构：AVAudioEngine 录音 → ffmpeg 流式写入 Named Pipe → Python VAD处理
class VADWhisperService: ObservableObject {
    static let shared = VADWhisperService()

    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var silenceTimer: Timer?
    private var lastAudioTime = Date()
    private var pipePath: String?
    private var process: Process?
    private var sseTask: URLSessionDataTask?
    private var partialResult = ""
    private var session: URLSession?
    
    /// 静默阈值（秒）
    private let silenceThreshold: TimeInterval = 2.0
    /// Python 服务端口
    private let ssePort = 8765

    private init() {
        session = URLSession(configuration: .default)
    }

    // MARK: - 权限检查

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - 开始录音 + VAD 识别

    func startRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        partialResult = ""
        lastAudioTime = Date()

        // 创建 Named Pipe
        let tempDir = FileManager.default.temporaryDirectory
        let pipeName = "vad_whisper_\(UUID().uuidString).pipe"
        pipePath = tempDir.appendingPathComponent(pipeName).path

        guard let pipePath = pipePath else { return }

        // 删除旧的 pipe
        try? FileManager.default.removeItem(atPath: pipePath)
        Foundation.PipeCoordinator.shared.makeNamedPipe(atPath: pipePath)

        // 启动 Python VAD 服务
        startVADService(pipePath: pipePath, onPartial: onPartial, onFinal: onFinal)

        // 启动 ffmpeg 监听（写入 pipe）
        startFFmpegWriter(pipePath: pipePath)

        // 启动录音
        startAudioCapture(pipePath: pipePath, onPartial: onPartial, onFinal: onFinal)
    }

    private func startVADService(pipePath: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        // 启动 Python 脚本
        let scriptPath = Bundle.main.path(forResource: "stream_whisper", ofType: "py",
                                           inDirectory: "scripts") ?? "/Users/vincent/Projects/spoken/scripts/stream_whisper.py"

        process = Process()
        process?.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process?.arguments = [scriptPath, pipePath]
        process?.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process?.standardOutput = pipe
        process?.standardError = pipe

        // 读取 stderr 日志
        let stderrHandle = pipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("Python: \(str)")
            }
        }

        do {
            try process?.run()
            print("VADWhisperService: [DEBUG] Python VAD process started")
        } catch {
            print("VADWhisperService: [ERROR] Failed to start VAD process: \(error)")
            isRecording = false
            return
        }

        // 等待 SSE 服务启动（给 3 秒加载模型）
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.connectSSE(onPartial: onPartial, onFinal: onFinal)
        }
    }

    private func connectSSE(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        // 连接 SSE 获取识别结果
        guard let url = URL(string: "http://127.0.0.1:\(ssePort)/stream") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval.infinity
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let task = session?.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            
            // 解析 SSE 数据
            if let text = String(data: data, encoding: .utf8) {
                self.parseSSE(text: text, onPartial: onPartial, onFinal: onFinal)
            }
        }
        sseTask = task
        task?.resume()
    }

    private func parseSSE(text: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        // SSE 格式: event: partial\ndata: {"type": "partial", "data": "..."}\n\n
        let lines = text.components(separatedBy: "\n")
        var eventType = ""
        var eventData = ""

        for line in lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                eventData = String(line.dropFirst(6))
            } else if line.isEmpty && !eventType.isEmpty && !eventData.isEmpty {
                // 空行表示事件结束
                if let jsonData = eventData.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let type = json["type"] as? String,
                   let data = json["data"] as? String {
                    DispatchQueue.main.async {
                        if type == "partial" {
                            self.partialResult = data
                            onPartial(data)
                        } else if type == "final" {
                            self.partialResult = data
                            onFinal(data)
                        }
                    }
                }
                eventType = ""
                eventData = ""
            }
        }
    }

    private func startFFmpegWriter(pipePath: String) {
        // ffmpeg 监听 - 从麦克风读取 PCM 写入 named pipe
        // 注意：这里我们直接让录音 capture 到 pipe，不单独起 ffmpeg 进程
        // ffmpeg 的作用在 Python 端处理
        print("VADWhisperService: [DEBUG] FFmpeg writer ready")
    }

    private func startAudioCapture(pipePath: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine,
              let inputNode = audioEngine.inputNode else {
            print("VADWhisperService: [ERROR] audioEngine setup failed")
            isRecording = false
            return
        }

        let format = inputNode.outputFormat(forBus: 0)
        print("VADWhisperService: [DEBUG] input format: \(format)")

        // 打开 Named Pipe 写端
        let pipeFd = open(pipePath, O_WRONLY | O_NONBLOCK)
        guard pipeFd >= 0 else {
            print("VADWhisperService: [ERROR] cannot open pipe: \(pipePath)")
            isRecording = false
            return
        }

        // 直接把 PCM 数据写入 Named Pipe
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            // 转为 16bit mono PCM
            guard let pcmData = self.convertToPCM(buffer: buffer) else { return }

            // 写入 pipe
            let written = pcmData.write(toFD: pipeFd, options: [], totalBytes: pcmData.count)
            if written < 0 && errno != EAGAIN {
                print("VADWhisperService: [WARN] pipe write error: \(written)")
            }

            self.lastAudioTime = Date()
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("VADWhisperService: [DEBUG] audioEngine started")
        } catch {
            print("VADWhisperService: [ERROR] audioEngine start failed: \(error)")
            isRecording = false
            close(pipeFd)
            return
        }

        // 静默检测 + 最终超时
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isRecording && Date().timeIntervalSince(self.lastAudioTime) > self.silenceThreshold {
                print("VADWhisperService: [DEBUG] silence detected")
                self.finishRecording(onPartial: onPartial, onFinal: onFinal)
            }
        }
    }

    private func finishRecording(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        guard isRecording else { return }
        isRecording = false
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // 关闭 Python 进程
        process?.terminate()
        process = nil

        sseTask?.cancel()
        sseTask = nil

        // 清理 pipe
        if let pipePath = pipePath {
            try? FileManager.default.removeItem(atPath: pipePath)
            pipePath = nil
        }

        // 最终文本已在 SSE 的 final 事件中传递
        let finalText = partialResult
        print("VADWhisperService: [DEBUG] finished, final: \(finalText)")

        DispatchQueue.main.async {
            if !finalText.isEmpty {
                onFinal(finalText)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine?.stop()
        audioEngine = nil
        process?.terminate()
        process = nil
        sseTask?.cancel()
        if let pipePath = pipePath {
            try? FileManager.default.removeItem(atPath: pipePath)
            self.pipePath = nil
        }
    }

    // MARK: - 音频格式转换

    private func convertToPCM(buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate

        // 混音为单声道
        var mono = [Float](repeating: 0, count: frameLength)
        for ch in 0..<channelCount {
            let chData = channelData[ch]
            for i in 0..<frameLength {
                mono[i] += chData[i]
            }
        }
        for i in 0..<frameLength { mono[i] /= Float(channelCount) }

        // float → int16
        var pcm = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let s = max(-1.0, min(1.0, mono[i]))
            pcm[i] = Int16(s * 32767.0)
        }

        return Data(bytes: pcm, count: frameLength * 2)
    }
}

// MARK: - Named Pipe 辅助

extension PipeCoordinator {
    func makeNamedPipe(atPath path: String) {
        // mkfifo 系统调用创建 FIFO
        let result = path.withCString { cPath in
            mkfifo(cPath, S_IRUSR | S_IWUSR)
        }
        if result != 0 {
            print("VADWhisperService: [ERROR] mkfifo failed: \(result)")
        }
    }
}
