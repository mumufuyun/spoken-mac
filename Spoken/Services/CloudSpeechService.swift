import Foundation
import os
import Combine

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
        provider(id: "dashscope")
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

// MARK: - DashScope Provider 实现

/// DashScope (阿里云) 流式语音识别 Provider
class DashScopeSpeechProvider: NSObject, CloudSpeechProvider {
    static let shared = DashScopeSpeechProvider()
    private static let logger = Logger(subsystem: "com.moss.spoken", category: "DashScopeProvider")

    let providerId = "dashscope"
    let displayName = "阿里云 DashScope"

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
    private var accumulatedText: String = ""

    private var _connectionState: CloudConnectionState = .idle
    private var _onConnectionStateChanged: ((CloudConnectionState) -> Void)?

    var connectionState: CloudConnectionState { _connectionState }
    var onConnectionStateChanged: ((CloudConnectionState) -> Void)? {
        get { _onConnectionStateChanged }
        set { _onConnectionStateChanged = newValue }
    }

    var isReady: Bool { isWebSocketOpen && hasTaskStarted }

    private override init() { super.init() }

    private func logInfo(_ msg: String) {
        Self.logger.info("\(msg, privacy: .public)")
    }
    private func logWarn(_ msg: String) {
        Self.logger.warning("\(msg, privacy: .public)")
    }
    private func logError(_ msg: String) {
        Self.logger.error("\(msg, privacy: .public)")
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
        guard !key.isEmpty else {
            updateState(.failed("未配置 API Key"))
            onError(CloudSpeechError.missingAPIKey)
            return
        }

        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        self.accumulatedText = ""

        let effectiveModel = model.isEmpty ? (UserDefaults.standard.string(forKey: "speech_model_name") ?? "fun-asr-flash-8k-realtime") : model

        if isWebSocketOpen, webSocketTask != nil {
            cancelPreconnect()
            self.effectiveModel = effectiveModel
            if !hasTaskStarted {
                sendStartMessage(model: effectiveModel)
            }
            onConnected?()
            return
        }

        disconnect()
        updateState(.connecting)
        self.effectiveModel = effectiveModel

        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference") else {
            updateState(.failed("无效的 URL"))
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
        let model = UserDefaults.standard.string(forKey: "speech_model_name") ?? "fun-asr-flash-8k-realtime"
        if isWebSocketOpen { return }

        disconnect()
        updateState(.connecting)
        self.effectiveModel = model

        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutInterval

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
        guard isWebSocketOpen, hasTaskStarted, let task = webSocketTask else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            if let error = error {
                Self.shared.logError("sendAudio failed: \(error.localizedDescription)")
                self?.handleError(error)
            }
        }
    }

    func finish() {
        guard isWebSocketOpen, let task = webSocketTask else { return }
        let finishMessage: [String: Any] = [
            "header": ["action": "finish-task", "task_id": currentTaskId, "streaming": "duplex"],
            "payload": ["input": [:]]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: finishMessage)
            let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8) ?? "")
            task.send(message) { [weak self] error in
                if let error = error { self?.handleError(error) }
            }
        } catch { handleError(error) }
    }

    func disconnect() {
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
        updateState(.disconnected)
    }

    private func sendStartMessage(model: String) {
        guard let task = webSocketTask else { return }
        let taskId = UUID().uuidString
        currentTaskId = taskId
        let startMessage: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": model, "input": [:],
                "parameters": ["format": "pcm", "sample_rate": 16000]
            ]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: startMessage)
            guard let jsonString = String(data: data, encoding: .utf8) else { return }
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            task.send(message) { [weak self] error in
                if let error = error { self?.handleError(error) }
            }
        } catch { handleError(error) }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Self.shared.logError("WebSocket receive error: \(error.localizedDescription)")
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
        case .string(let text): parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { parseResponse(text) }
        @unknown default: break
        }
    }

    private func parseResponse(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let header = json["header"] as? [String: Any],
           let event = header["event"] as? String {
            if event == "error" || event == "task-failed" {
                let errorMessage = (json["payload"] as? [String: Any])?["message"] as? String
                    ?? (header["error_message"] as? String) ?? "Unknown error"
                updateState(.failed("API 错误: \(errorMessage)"))
                handleError(CloudSpeechError.apiError(errorMessage))
                return
            }
            if event == "task-started" {
                hasTaskStarted = true
                return
            }
            if event == "task-finished" { return }
        }

        if let payload = json["payload"] as? [String: Any],
           let output = payload["output"] as? [String: Any],
           let sentence = output["sentence"] as? [String: Any] {
            let text = sentence["text"] as? String ?? ""
            let isFinal = sentence["sentence_end"] as? Bool ?? false
            if !text.isEmpty {
                if isFinal {
                    accumulatedText = accumulatedText.isEmpty ? text : accumulatedText + text
                    DispatchQueue.main.async { self.onPartial?(self.accumulatedText) }
                } else {
                    let displayText = accumulatedText.isEmpty ? text : accumulatedText + text
                    DispatchQueue.main.async { self.onPartial?(displayText) }
                }
            }
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

extension DashScopeSpeechProvider: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isWebSocketOpen = true
        cancelTimeoutTimer()
        cancelPreconnect()
        updateState(.connected)
        onConnected?()
        sendStartMessage(model: effectiveModel)
        receiveMessage()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isWebSocketOpen = false
        hasTaskStarted = false
        cancelTimeoutTimer()
        updateState(.disconnected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            isWebSocketOpen = false
            hasTaskStarted = false
            cancelTimeoutTimer()
            updateState(.failed("连接异常: \(error.localizedDescription)"))
            handleError(error)
        }
    }
}

// MARK: - 调度服务

/// 云端语音识别调度服务：管理 Provider 注册、状态监控、自检
class CloudSpeechService: NSObject {
    static let shared = CloudSpeechService()
    private static let logger = Logger(subsystem: "com.moss.spoken", category: "CloudSpeechService")

    private var currentProvider: CloudSpeechProvider?
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((Error) -> Void)?
    var onConnected: (() -> Void)?

    @Published private(set) var connectionState: CloudConnectionState = .idle
    private(set) var lastHealthReport: CloudHealthReport?

    private override init() {
        super.init()
        CloudSpeechProviderRegistry.shared.register(DashScopeSpeechProvider.shared)
    }

    private func logInfo(_ msg: String) {
        Self.logger.info("\(msg, privacy: .public)")
    }
    private func logWarn(_ msg: String) {
        Self.logger.warning("\(msg, privacy: .public)")
    }
    private func logError(_ msg: String) {
        Self.logger.error("\(msg, privacy: .public)")
    }

    private func resolveProvider() -> CloudSpeechProvider? {
        let providerId = UserDefaults.standard.string(forKey: "cloud_speech_provider") ?? "dashscope"
        let provider = CloudSpeechProviderRegistry.shared.provider(id: providerId)
        if provider == nil {
            logWarn("Provider '\(providerId)' not found, falling back to dashscope")
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
}
