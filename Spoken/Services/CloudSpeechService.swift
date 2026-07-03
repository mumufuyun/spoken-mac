import Foundation
import Combine
import os

// MARK: - 文件日志工具

/// 将日志写入 ~/Library/Application Support/com.moss.spoken/Logs/spoken.log
/// 支持按日期轮转（保留最近 7 天）
class FileLogger {
    static let shared = FileLogger()

    private let logDirectory: URL
    private let logFile: URL
    private let dateFormatter: DateFormatter
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.moss.spoken.filelogger", qos: .utility)

    private init() {
        // 使用 Application Support 目录，避免 hardened runtime 限制
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.moss.spoken", isDirectory: true)
        logDirectory = appSupport.appendingPathComponent("Logs", isDirectory: true)
        logFile = logDirectory.appendingPathComponent("spoken.log")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: nil)
            UnifiedLogger(subsystem: "com.moss.spoken", category: "FileLogger").info("Log directory: \(logDirectory.path)")
        } catch {
            UnifiedLogger(subsystem: "com.moss.spoken", category: "FileLogger").error("Failed to create log directory: \(error)")
        }

        rotateIfNeeded()
    }

    func log(_ level: String, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.rotateIfNeeded()

            let timestamp = self.dateFormatter.string(from: Date())
            let fileName = (file as NSString).lastPathComponent
            let logLine = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)\n"

            if let data = logLine.data(using: .utf8) {
                if self.fileManager.fileExists(atPath: self.logFile.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFile) {
                        _ = handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: self.logFile, options: .atomic)
                }
            }
        }
    }

    var currentLogFilePath: String { logFile.path }

    func readRecentLogs(maxLines: Int = 200) -> String {
        guard let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        let lines = text.components(separatedBy: .newlines)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func rotateIfNeeded() {
        guard fileManager.fileExists(atPath: logFile.path) else { return }
        guard let attrs = try? fileManager.attributesOfItem(atPath: logFile.path),
              let creationDate = attrs[.creationDate] as? Date else { return }

        if !Calendar.current.isDateInToday(creationDate) {
            let archiveName = "spoken-\(formatDate(creationDate)).log"
            let archiveFile = logDirectory.appendingPathComponent(archiveName)
            try? fileManager.moveItem(at: logFile, to: archiveFile)
            cleanupOldLogs()
        }
    }

    private func cleanupOldLogs() {
        guard let urls = try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix("spoken-") && name.hasSuffix(".log") {
                guard let date = parseDate(from: name) else { continue }
                if date < cutoff {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func parseDate(from fileName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let prefix = "spoken-"
        let suffix = ".log"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        let dateStr = String(fileName[start..<end])
        return formatter.date(from: dateStr)
    }
}

/// 统一日志封装：同时写入 os.Logger 和本地文件
struct UnifiedLogger {
    private let osLogger: os.Logger
    private let category: String

    init(subsystem: String, category: String) {
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLogger.info("\(message, privacy: .public)")
        FileLogger.shared.log("INFO", "[\(category)] \(message)", file: file, function: function, line: line)
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLogger.warning("\(message, privacy: .public)")
        FileLogger.shared.log("WARN", "[\(category)] \(message)", file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLogger.error("\(message, privacy: .public)")
        FileLogger.shared.log("ERROR", "[\(category)] \(message)", file: file, function: function, line: line)
    }
}

// MARK: - 连接状态

enum CloudConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    case disconnected

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Provider 协议

/// 所有云端语音识别 Provider 必须实现的协议
protocol CloudSpeechProvider: AnyObject {
    var providerId: String { get }
    var displayName: String { get }
    var connectionState: CloudConnectionState { get }
    var onConnectionStateChanged: ((CloudConnectionState) -> Void)? { get set }
    var isReady: Bool { get }

    func connect(apiKey: String?, model: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void)
    func sendAudio(_ data: Data)
    func finish()
    func disconnect()
    func preconnect()
    func cancelPreconnect()
}

// MARK: - Provider 注册表

class CloudSpeechProviderRegistry {
    static let shared = CloudSpeechProviderRegistry()
    private var providers: [String: CloudSpeechProvider] = [:]
    private let lock = NSLock()

    private init() {}

    func register(_ provider: CloudSpeechProvider) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.providerId] = provider
    }

    func provider(id: String) -> CloudSpeechProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    func defaultProvider() -> CloudSpeechProvider? {
        provider(id: "qwen-realtime")
    }

    func allProviders() -> [CloudSpeechProvider] {
        lock.lock()
        defer { lock.unlock() }
        return Array(providers.values)
    }
}

// MARK: - 自检报告

struct CloudHealthReport {
    let providerId: String
    let providerName: String
    let state: CloudConnectionState
    let isHealthy: Bool
    let details: String
}

// MARK: - 错误定义

enum CloudSpeechError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case timeout
    case connectionFailed
    case apiError(String)
    case providerNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidURL: return "无效的 WebSocket URL"
        case .timeout: return "连接超时"
        case .connectionFailed: return "连接失败"
        case .apiError(let msg): return "API 错误: \(msg)"
        case .providerNotFound(let id): return "未找到 Provider: \(id)"
        }
    }
}

// MARK: - CloudSpeechService 调度层

/// 云端语音识别调度服务：管理 Provider 注册、状态监控、自检
class CloudSpeechService: NSObject {
    static let shared = CloudSpeechService()
    private static let logger = UnifiedLogger(subsystem: "com.moss.spoken", category: "CloudSpeechService")

    private var currentProvider: CloudSpeechProvider?
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((Error) -> Void)?
    var onConnected: (() -> Void)?

    @Published private(set) var connectionState: CloudConnectionState = .idle
    private(set) var lastHealthReport: CloudHealthReport?

    private override init() {
        super.init()
        CloudSpeechProviderRegistry.shared.register(QwenRealtimeSpeechProvider.shared)
    }

    private func logInfo(_ msg: String) {
        Self.logger.info(msg)
    }
    private func logWarn(_ msg: String) {
        Self.logger.warning(msg)
    }
    private func logError(_ msg: String) {
        Self.logger.error(msg)
    }

    private func resolveProvider() -> CloudSpeechProvider? {
        let providerId = UserDefaults.standard.string(forKey: "cloud_speech_provider") ?? "qwen-realtime"
        let provider = CloudSpeechProviderRegistry.shared.provider(id: providerId)
        if provider == nil {
            logWarn("Provider '\(providerId)' not found, falling back to qwen-realtime")
            return CloudSpeechProviderRegistry.shared.defaultProvider()
        }
        return provider
    }

    func switchProvider(to providerId: String) {
        logInfo("Switching provider to: \(providerId)")
        disconnect()
        UserDefaults.standard.set(providerId, forKey: "cloud_speech_provider")
    }

    private func bindProviderState(_ provider: CloudSpeechProvider) {
        provider.onConnectionStateChanged = { [weak self] state in
            self?.connectionState = state
        }
    }

    func connect(apiKey: String? = nil, model: String = "", onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        guard let provider = resolveProvider() else {
            connectionState = .failed("未找到可用的云端识别服务")
            onError(CloudSpeechError.providerNotFound("default"))
            return
        }
        if let current = currentProvider, current.providerId != provider.providerId {
            current.disconnect()
        }
        currentProvider = provider
        bindProviderState(provider)
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        provider.connect(apiKey: apiKey, model: model, onPartial: onPartial, onFinal: onFinal, onError: onError)
    }

    func preconnect() {
        guard let provider = resolveProvider() else { return }
        if let current = currentProvider, current.providerId != provider.providerId {
            current.disconnect()
        }
        currentProvider = provider
        bindProviderState(provider)
        provider.preconnect()
    }

    func sendAudio(_ data: Data) {
        currentProvider?.sendAudio(data)
    }

    func finish() {
        currentProvider?.finish()
    }

    func disconnect() {
        currentProvider?.disconnect()
        currentProvider = nil
        connectionState = .idle
    }

    func performHealthCheck() -> CloudHealthReport {
        guard let provider = currentProvider ?? resolveProvider() else {
            let report = CloudHealthReport(providerId: "unknown", providerName: "未知", state: .failed("未配置"), isHealthy: false, details: "未配置云端识别 Provider")
            lastHealthReport = report
            return report
        }
        let isHealthy = provider.isReady
        let report = CloudHealthReport(
            providerId: provider.providerId,
            providerName: provider.displayName,
            state: provider.connectionState,
            isHealthy: isHealthy,
            details: isHealthy ? "连接正常" : provider.connectionState.isFailed ? "连接失败" : "未连接"
        )
        lastHealthReport = report
        return report
    }

    var isReady: Bool { currentProvider?.isReady ?? false }
    var currentProviderName: String { currentProvider?.displayName ?? resolveProvider()?.displayName ?? "未配置" }

    func availableProviders() -> [(id: String, name: String)] {
        return CloudSpeechProviderRegistry.shared.allProviders().map {
            (id: $0.providerId, name: $0.displayName)
        }
    }
}

// MARK: - Qwen Realtime Provider

/// 千问云 (Qwen) Realtime 语音识别 Provider 实现
/// 基于 OpenAI Realtime API 兼容协议
class QwenRealtimeSpeechProvider: NSObject, CloudSpeechProvider {
    static let shared = QwenRealtimeSpeechProvider()
    private static let logger = UnifiedLogger(subsystem: "com.moss.spoken", category: "QwenRealtimeProvider")

    let providerId = "qwen-realtime"
    let displayName = "千问云 Realtime"

    private var webSocketTask: URLSessionWebSocketTask?
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((Error) -> Void)?
    var onConnected: (() -> Void)?

    private(set) var isWebSocketOpen = false
    private var sessionCreated = false
    private var effectiveModel: String = ""
    private let timeoutInterval: TimeInterval = 30
    private var timeoutWorkItem: DispatchWorkItem?
    private var preconnectWorkItem: DispatchWorkItem?
    private let preconnectTimeout: TimeInterval = 8
    private var accumulatedText: String = ""

    private var _connectionState: CloudConnectionState = .idle
    private var _onConnectionStateChanged: ((CloudConnectionState) -> Void)?

    var connectionState: CloudConnectionState { _connectionState }
    var onConnectionStateChanged: ((CloudConnectionState) -> Void)? {
        get { _onConnectionStateChanged }
        set { _onConnectionStateChanged = newValue }
    }

    var isReady: Bool { isWebSocketOpen && sessionCreated }

    private override init() { super.init() }

    private func logInfo(_ msg: String) {
        Self.logger.info(msg)
    }
    private func logWarn(_ msg: String) {
        Self.logger.warning(msg)
    }
    private func logError(_ msg: String) {
        Self.logger.error(msg)
    }

    private func updateState(_ newState: CloudConnectionState) {
        guard _connectionState != newState else { return }
        _connectionState = newState
        DispatchQueue.main.async { [weak self] in
            self?._onConnectionStateChanged?(newState)
        }
    }

    func connect(apiKey: String? = nil, model: String = "", onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        let key = apiKey ?? SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        logInfo("connect: apiKey length=\(key.count), source=\(apiKey != nil ? "provided" : "keychain/defaults")")
        guard !key.isEmpty else {
            logError("connect: API Key is empty")
            updateState(.failed("未配置 API Key"))
            onError(CloudSpeechError.missingAPIKey)
            return
        }

        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        self.accumulatedText = ""

        let effectiveModel = model.isEmpty
            ? (UserDefaults.standard.string(forKey: "speech_model_name") ?? "qwen3-asr-flash-realtime")
            : model

        logInfo("connect called, model=\(effectiveModel)")

        if isWebSocketOpen, webSocketTask != nil {
            cancelPreconnect()
            self.effectiveModel = effectiveModel
            if !sessionCreated {
                sendSessionUpdate()
            }
            onConnected?()
            return
        }

        disconnect()
        updateState(.connecting)
        self.effectiveModel = effectiveModel

        let baseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        guard let url = URL(string: "\(baseURL)?model=\(effectiveModel)") else {
            updateState(.failed("无效的 URL"))
            onError(CloudSpeechError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = timeoutInterval

        logInfo("connect: creating WebSocket task to \(url)")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.delegate = self
        self.webSocketTask = task
        task.resume()
        startTimeoutTimer()
    }

    func preconnect() {
        cancelPreconnect()
        let key = SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        guard !key.isEmpty else {
            updateState(.failed("未配置 API Key"))
            return
        }
        let model = UserDefaults.standard.string(forKey: "speech_model_name") ?? "qwen3-asr-flash-realtime"
        if isWebSocketOpen { return }

        disconnect()
        updateState(.connecting)
        self.effectiveModel = model

        let baseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        guard let url = URL(string: "\(baseURL)?model=\(model)") else {
            updateState(.failed("无效的 URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = timeoutInterval

        logInfo("preconnect starting for model=\(model)...")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.delegate = self
        self.webSocketTask = task
        task.resume()

        let workItem = DispatchWorkItem { [weak self] in
            self?.updateState(.failed("连接超时"))
            self?.disconnect()
        }
        preconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + preconnectTimeout, execute: workItem)
    }

    func cancelPreconnect() {
        preconnectWorkItem?.cancel()
        preconnectWorkItem = nil
    }

    func sendAudio(_ data: Data) {
        guard isWebSocketOpen, sessionCreated, let task = webSocketTask else {
            logWarn("sendAudio ignored, open=\(isWebSocketOpen), session=\(sessionCreated)")
            return
        }

        let encoded = data.base64EncodedString()
        let event: [String: Any] = [
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))",
            "type": "input_audio_buffer.append",
            "audio": encoded
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: event)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            task.send(message) { [weak self] error in
                if let error = error {
                    Self.logger.error("sendAudio failed: \(error.localizedDescription)")
                    self?.handleError(error)
                }
            }
        } catch {
            logError("audio event encode failed: \(error)")
            handleError(error)
        }
    }

    func finish() {
        guard isWebSocketOpen, let task = webSocketTask else {
            logWarn("finish ignored, not connected")
            return
        }

        let event: [String: Any] = [
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))",
            "type": "input_audio_buffer.commit"
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: event)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            logInfo("sending input_audio_buffer.commit")
            task.send(message) { [weak self] error in
                if let error = error { self?.handleError(error) }
            }
        } catch { handleError(error) }
    }

    func disconnect() {
        logInfo("disconnect called")
        cancelTimeoutTimer()
        cancelPreconnect()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isWebSocketOpen = false
        sessionCreated = false
        accumulatedText = ""
        onPartial = nil
        onFinal = nil
        onError = nil
        onConnected = nil
        effectiveModel = ""
        updateState(.disconnected)
    }

    private func sendSessionUpdate() {
        guard let task = webSocketTask else { return }

        // 注意：turn_detection 必须完全省略，不能传 null，否则服务端会断开连接
        let event: [String: Any] = [
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))",
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": 16000,
                "input_audio_transcription": [
                    "language": "zh"
                ]
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: event, options: .prettyPrinted)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
            logInfo("sending session.update: \(jsonString)")
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            task.send(message) { [weak self] error in
                if let error = error {
                    Self.logger.error("session.update send failed: \(error.localizedDescription)")
                    self?.handleError(error)
                } else {
                    Self.logger.info("session.update sent successfully")
                }
            }
        } catch { handleError(error) }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.handleError(error)
            case .success(let message):
                self.cancelTimeoutTimer()
                self.handleMessage(message)
                if self.isWebSocketOpen { self.receiveMessage() }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            logInfo("received: \(text)")
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { parseResponse(text) }
        @unknown default: break
        }
    }

    private func parseResponse(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        guard let type = json["type"] as? String else { return }

        switch type {
        case "session.created":
            sessionCreated = true
            logInfo("session created")
            onConnected?()

        case "session.updated":
            logInfo("session updated")

        case "input_audio_buffer.committed":
            logInfo("audio buffer committed")

        case "conversation.item.input_audio_transcription.completed":
            // 新格式: 直接包含 transcript 字段
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                accumulatedText = accumulatedText.isEmpty ? transcript : accumulatedText + transcript
                DispatchQueue.main.async { self.onPartial?(self.accumulatedText) }
            }
            // 旧格式: 嵌套在 item 中
            else if let item = json["item"] as? [String: Any],
                    let content = item["content"] as? [[String: Any]],
                    let first = content.first,
                    let transcript = first["transcript"] as? String, !transcript.isEmpty {
                accumulatedText = accumulatedText.isEmpty ? transcript : accumulatedText + transcript
                DispatchQueue.main.async { self.onPartial?(self.accumulatedText) }
            }

        case "conversation.item.input_audio_transcription.delta":
            // 新格式
            if let delta = json["delta"] as? String, !delta.isEmpty {
                let displayText = accumulatedText.isEmpty ? delta : accumulatedText + delta
                DispatchQueue.main.async { self.onPartial?(displayText) }
            }
            // 旧格式: 嵌套在 item 中
            else if let item = json["item"] as? [String: Any],
                    let content = item["content"] as? [[String: Any]],
                    let first = content.first,
                    let delta = first["delta"] as? String, !delta.isEmpty {
                let displayText = accumulatedText.isEmpty ? delta : accumulatedText + delta
                DispatchQueue.main.async { self.onPartial?(displayText) }
            }

        case "error":
            let errorMsg = json["error"] as? [String: Any]
            let message = errorMsg?["message"] as? String ?? "Unknown error"
            let code = errorMsg?["code"] as? String ?? "unknown"
            logError("API error: code=\(code), message=\(message)")
            updateState(.failed("API 错误: \(message)"))
            handleError(CloudSpeechError.apiError(message))

        default:
            logInfo("unhandled event type: \(type)")
        }
    }

    private func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    private func startTimeoutTimer() {
        cancelTimeoutTimer()
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateState(.failed("连接超时"))
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

extension QwenRealtimeSpeechProvider: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let proto = `protocol` ?? "nil"
        logInfo("WebSocket connected, protocol=\(proto)")
        isWebSocketOpen = true
        cancelTimeoutTimer()
        cancelPreconnect()
        updateState(.connected)
        // 延迟发送 session.update，确保连接完全建立
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendSessionUpdate()
            self?.receiveMessage()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        logInfo("WebSocket closed: code=\(closeCode.rawValue), reason=\(reasonStr)")
        isWebSocketOpen = false
        sessionCreated = false
        cancelTimeoutTimer()
        updateState(.disconnected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logError("WebSocket task error: \(error.localizedDescription)")
            isWebSocketOpen = false
            sessionCreated = false
            cancelTimeoutTimer()
            updateState(.failed("连接异常: \(error.localizedDescription)"))
            handleError(error)
        } else {
            logInfo("WebSocket task completed without error")
        }
    }
}
