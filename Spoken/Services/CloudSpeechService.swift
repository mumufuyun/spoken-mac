import Foundation
import os

/// DashScope 流式语音识别 WebSocket 客户端
/// 协议文档: https://help.aliyun.com/zh/model-studio/websocket-for-paraformer-real-time-service
class CloudSpeechService: NSObject {
    static let shared = CloudSpeechService()
    private static let logger = Logger(subsystem: "com.moss.spoken", category: "CloudSpeech")

    private var webSocketTask: URLSessionWebSocketTask?
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((Error) -> Void)?
    var onConnected: (() -> Void)?

    private(set) var isWebSocketOpen = false
    private(set) var hasTaskStarted = false
    private var effectiveModel: String = ""
    private var currentTaskId: String = ""
    private let timeoutInterval: TimeInterval = 30
    private var timeoutWorkItem: DispatchWorkItem?

    private var preconnectWorkItem: DispatchWorkItem?
    private let preconnectTimeout: TimeInterval = 8

    /// 累积已完成的句子文本（sentence_end 之前的句子）
    private var accumulatedText: String = ""

    private override init() {}

    // MARK: - 日志辅助

    private func logInfo(_ msg: String) {
        Self.logger.info("\(msg, privacy: .public)")
    }

    private func logWarn(_ msg: String) {
        Self.logger.warning("\(msg, privacy: .public)")
    }

    private func logError(_ msg: String) {
        Self.logger.error("\(msg, privacy: .public)")
    }

    // MARK: - 连接

    func connect(
        apiKey: String? = nil,
        model: String = "",
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let key = apiKey ?? SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        guard !key.isEmpty else {
            logError("connect aborted: missing API key")
            onError(CloudSpeechError.missingAPIKey)
            return
        }

        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        self.accumulatedText = ""

        let effectiveModel = model.isEmpty ? (UserDefaults.standard.string(forKey: "speech_model_name") ?? "fun-asr-flash-8k-realtime") : model

        logInfo("cloud connect called, isWebSocketOpen=\(isWebSocketOpen), hasTaskStarted=\(hasTaskStarted)")

        if isWebSocketOpen, webSocketTask != nil {
            cancelPreconnect()
            self.effectiveModel = effectiveModel
            if !hasTaskStarted {
                logInfo("reusing open connection, sending start message")
                sendStartMessage(model: effectiveModel)
            } else {
                logInfo("reusing open connection, task already started")
            }
            onConnected?()
            return
        }

        logInfo("no open connection, creating new one")
        disconnect()

        self.effectiveModel = effectiveModel

        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference") else {
            onError(CloudSpeechError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutInterval

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.delegate = self
        self.webSocketTask = task

        logInfo("resuming webSocketTask")
        task.resume()
        startTimeoutTimer()
    }

    // MARK: - 预连接

    func preconnect() {
        cancelPreconnect()

        let key = SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        guard !key.isEmpty else {
            logInfo("preconnect skipped: no API key")
            return
        }

        let model = UserDefaults.standard.string(forKey: "speech_model_name") ?? "fun-asr-flash-8k-realtime"

        if isWebSocketOpen {
            logInfo("preconnect skipped: already open")
            return
        }

        disconnect()

        self.effectiveModel = model

        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutInterval

        logInfo("preconnect starting...")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.delegate = self
        self.webSocketTask = task

        task.resume()

        let workItem = DispatchWorkItem { [weak self] in
            Self.shared.logWarn("Preconnect timeout, disconnecting")
            self?.disconnect()
        }
        preconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preconnectTimeout, execute: workItem)
    }

    func cancelPreconnect() {
        preconnectWorkItem?.cancel()
        preconnectWorkItem = nil
    }

    // MARK: - 发送音频

    func sendAudio(_ data: Data) {
        guard isWebSocketOpen, hasTaskStarted, let task = webSocketTask else {
            logWarn("sendAudio ignored, open=\(isWebSocketOpen), started=\(hasTaskStarted)")
            return
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            if let error = error {
                Self.shared.logError("sendAudio failed: \(error.localizedDescription)")
                self?.handleError(error)
            }
        }
    }

    // MARK: - 结束标记

    func finish() {
        guard isWebSocketOpen, let task = webSocketTask else {
            logWarn("finish ignored, not connected")
            return
        }

        let finishMessage: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": currentTaskId,
                "streaming": "duplex"
            ],
            "payload": [
                "input": [:]
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: finishMessage)
            let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8) ?? "")
            logInfo("sending finish-task, taskId=\(currentTaskId)")
            task.send(message) { [weak self] error in
                if let error = error {
                    Self.shared.logError("finish message failed: \(error.localizedDescription)")
                    self?.handleError(error)
                }
            }
        } catch {
            logError("finish message encode failed: \(error.localizedDescription)")
            handleError(error)
        }
    }

    // MARK: - 断开连接

    func disconnect() {
        logInfo("disconnect called")
        cancelTimeoutTimer()
        cancelPreconnect()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isWebSocketOpen = false
        hasTaskStarted = false
        accumulatedText = ""
        onPartial = nil
        onFinal = nil
        onError = nil
        onConnected = nil
        effectiveModel = ""
        currentTaskId = ""
    }

    // MARK: - 私有方法

    private func sendStartMessage(model: String) {
        guard let task = webSocketTask else {
            logError("sendStartMessage failed: no webSocketTask")
            return
        }

        let taskId = UUID().uuidString
        currentTaskId = taskId

        let startMessage: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskId,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "input": [:],
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000
                ]
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: startMessage)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                logError("start message string encode failed")
                return
            }
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            logInfo("sending run-task, model=\(model), taskId=\(taskId)")
            logInfo("run-task payload: \(jsonString)")
            task.send(message) { [weak self] error in
                if let error = error {
                    Self.shared.logError("start message failed: \(error.localizedDescription)")
                    self?.handleError(error)
                } else {
                    Self.shared.logInfo("start message sent successfully")
                }
            }
        } catch {
            logError("start message encode failed: \(error.localizedDescription)")
            handleError(error)
        }
    }

    private func receiveMessage() {
        logInfo("receiveMessage called")
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                Self.shared.logError("WebSocket receive error: \(error.localizedDescription)")
                self.handleError(error)
            case .success(let message):
                self.cancelTimeoutTimer()
                self.handleMessage(message)
                if self.isWebSocketOpen {
                    self.receiveMessage()
                } else {
                    Self.shared.logInfo("receiveMessage loop stopped, isWebSocketOpen=false")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            logInfo("received string message: \(text)")
            parseResponse(text)
        case .data(let data):
            logInfo("received binary data, length=\(data.count)")
            if let text = String(data: data, encoding: .utf8) {
                logInfo("binary data decoded as string: \(text)")
                parseResponse(text)
            } else {
                logWarn("binary data could not be decoded as UTF-8 string")
            }
        @unknown default:
            logWarn("received unknown message type")
        }
    }

    private func parseResponse(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            logError("parseResponse: text to data failed")
            return
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("parseResponse: JSON parse failed, raw text: \(text)")
                return
            }

            let keysStr = json.keys.sorted().joined(separator: ",")
            logInfo("parseResponse JSON keys: \(keysStr)")

            // 检查错误响应
            if let header = json["header"] as? [String: Any] {
                let headerStr = header.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                logInfo("response header: \(headerStr)")

                if let event = header["event"] as? String {
                    logInfo("response event: \(event)")

                    if event == "error" || event == "task-failed" {
                        let errorMessage = (json["payload"] as? [String: Any])?["message"] as? String
                            ?? (header["error_message"] as? String)
                            ?? "Unknown error"
                        let errorCode = header["error_code"] as? String ?? "nil"
                        logError("cloud API error: code=\(errorCode), message=\(errorMessage)")
                        handleError(CloudSpeechError.apiError(errorMessage))
                        return
                    }

                    // 任务启动成功
                    if event == "task-started" {
                        logInfo("cloud task started, ready for audio")
                        hasTaskStarted = true
                        return
                    }

                    // 任务完成
                    if event == "task-finished" {
                        logInfo("cloud task finished")
                        return
                    }
                }
            }

            // 解析识别结果 (result-generated)
            if let payload = json["payload"] as? [String: Any] {
                let payloadKeysStr = payload.keys.sorted().joined(separator: ",")
                logInfo("response payload keys: \(payloadKeysStr)")

                if let output = payload["output"] as? [String: Any] {
                    let outputKeysStr = output.keys.sorted().joined(separator: ",")
                    logInfo("response output keys: \(outputKeysStr)")

                    // 处理 sentence 结果
                    if let sentence = output["sentence"] as? [String: Any] {
                        let sentenceKeysStr = sentence.keys.sorted().joined(separator: ",")
                        logInfo("response sentence keys: \(sentenceKeysStr)")
                        let text = sentence["text"] as? String ?? ""
                        let isFinal = sentence["sentence_end"] as? Bool ?? false

                        if !text.isEmpty {
                            if isFinal {
                                logInfo("cloud sentence final result: '\(text)'")
                                // 将已完成的句子累积起来
                                if accumulatedText.isEmpty {
                                    accumulatedText = text
                                } else {
                                    accumulatedText += text
                                }
                                // 回调返回全部已识别文本（已完成 + 当前）
                                DispatchQueue.main.async { self.onPartial?(self.accumulatedText) }
                            } else {
                                logInfo("cloud partial result: '\(text)'")
                                // partial 结果 = 已完成句子 + 当前正在识别的句子
                                let displayText = accumulatedText.isEmpty ? text : accumulatedText + text
                                DispatchQueue.main.async { self.onPartial?(displayText) }
                            }
                        } else {
                            logInfo("sentence text is empty")
                        }
                    } else {
                        logInfo("no sentence in output")
                    }
                } else {
                    logInfo("no output in payload")
                }
            } else {
                logInfo("no payload in response")
            }
        } catch {
            logError("parse response failed: \(error.localizedDescription), raw text: \(text)")
        }
    }

    private func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func startTimeoutTimer() {
        cancelTimeoutTimer()
        let workItem = DispatchWorkItem { [weak self] in
            Self.shared.logError("WebSocket connection timeout")
            self?.handleError(CloudSpeechError.timeout)
            self?.disconnect()
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }

    private func cancelTimeoutTimer() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CloudSpeechService: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let proto = `protocol` ?? "nil"
        logInfo("WebSocket connected, protocol=\(proto)")
        isWebSocketOpen = true
        cancelTimeoutTimer()
        cancelPreconnect()
        onConnected?()
        sendStartMessage(model: effectiveModel)
        receiveMessage()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        logInfo("WebSocket closed: code=\(closeCode.rawValue), reason=\(reasonStr)")
        isWebSocketOpen = false
        hasTaskStarted = false
        cancelTimeoutTimer()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            logError("WebSocket task error: \(error.localizedDescription)")
            isWebSocketOpen = false
            hasTaskStarted = false
            cancelTimeoutTimer()
            handleError(error)
        } else {
            logInfo("WebSocket task completed without error")
        }
    }
}

// MARK: - 错误定义

enum CloudSpeechError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case timeout
    case connectionFailed
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidURL: return "无效的 WebSocket URL"
        case .timeout: return "连接超时"
        case .connectionFailed: return "连接失败"
        case .apiError(let msg): return "API 错误: \(msg)"
        }
    }
}
