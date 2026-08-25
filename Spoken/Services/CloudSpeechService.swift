import Foundation
import Combine
import os

// MARK: - 文件日志工具

/// 将日志写入 ~/Library/Application Support/com.moss.spoken/Logs/spoken.log
/// 支持按日期轮转（保留最近 7 天）
final class FileLogger: @unchecked Sendable {
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
        } catch {
            // 目录创建失败时静默处理，避免初始化时抛出
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
        queue.sync {
            guard let data = try? Data(contentsOf: logFile),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            let lines = text.components(separatedBy: .newlines)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
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
struct UnifiedLogger: Sendable {
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
    func finish(completion: @escaping (String?) -> Void)
    func disconnect()
    func preconnect()
    func cancelPreconnect()
}

// MARK: - Provider 注册表

final class CloudSpeechProviderRegistry: @unchecked Sendable {
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
    case recognitionStalled
    case apiError(String)
    case providerNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidURL: return "无效的 WebSocket URL"
        case .timeout: return "连接超时"
        case .connectionFailed: return "连接失败"
        case .recognitionStalled: return "云端识别无响应"
        case .apiError(let msg): return "API 错误: \(msg)"
        case .providerNotFound(let id): return "未找到 Provider: \(id)"
        }
    }
}

// MARK: - CloudSpeechService 调度层

/// 云端语音识别调度服务：管理 Provider 注册、状态监控、自检
final class CloudSpeechService: NSObject, @unchecked Sendable {
    static let shared = CloudSpeechService()
    private static let logger = UnifiedLogger(subsystem: "com.moss.spoken", category: "CloudSpeechService")

    private var currentProvider: CloudSpeechProvider?
    private let providerLock = NSLock()
    var onConnected: (() -> Void)?

    @Published private(set) var connectionState: CloudConnectionState = .idle
    private(set) var lastHealthReport: CloudHealthReport?

    private override init() {
        super.init()
        CloudSpeechProviderRegistry.shared.register(ReliableQwenSpeechProvider.shared)
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
            guard let self else { return }
            DispatchQueue.main.async {
                self.connectionState = state
                if case .connected = state {
                    self.onConnected?()
                }
            }
        }
    }

    private func lockedCurrentProvider() -> CloudSpeechProvider? {
        providerLock.lock()
        defer { providerLock.unlock() }
        return currentProvider
    }

    func connect(apiKey: String? = nil, model: String = "", onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        guard let provider = resolveProvider() else {
            connectionState = .failed("未找到可用的云端识别服务")
            onError(CloudSpeechError.providerNotFound("default"))
            return
        }
        if let current = lockedCurrentProvider(), current.providerId != provider.providerId {
            current.disconnect()
        }
        providerLock.lock()
        currentProvider = provider
        providerLock.unlock()
        bindProviderState(provider)
        provider.connect(apiKey: apiKey, model: model, onPartial: onPartial, onFinal: onFinal, onError: onError)
    }

    func preconnect() {
        guard let provider = resolveProvider() else { return }
        if let current = lockedCurrentProvider(), current.providerId != provider.providerId {
            current.disconnect()
        }
        providerLock.lock()
        currentProvider = provider
        providerLock.unlock()
        bindProviderState(provider)
        provider.preconnect()
    }

    func sendAudio(_ data: Data) {
        providerLock.lock()
        let provider = currentProvider
        providerLock.unlock()
        provider?.sendAudio(data)
    }

    func finish(completion: @escaping (String?) -> Void) {
        providerLock.lock()
        let provider = currentProvider
        providerLock.unlock()
        guard let provider else {
            completion(nil)
            return
        }
        provider.finish { [weak self] text in
            completion(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self else { return }
                let raw = UserDefaults.standard.string(forKey: "speechRecognitionProvider")
                    ?? SpeechRecognitionProvider.local.rawValue
                let recognitionProvider = SpeechRecognitionProvider(rawValue: raw) ?? .local
                if recognitionProvider == .cloud || recognitionProvider == .auto {
                    self.preconnect()
                }
            }
        }
    }

    func disconnect() {
        providerLock.lock()
        let provider = currentProvider
        currentProvider = nil
        providerLock.unlock()
        provider?.disconnect()
        connectionState = .idle
    }

    func performHealthCheck() -> CloudHealthReport {
        guard let provider = lockedCurrentProvider() ?? resolveProvider() else {
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

    var isReady: Bool { lockedCurrentProvider()?.isReady ?? false }
    var currentProviderName: String { lockedCurrentProvider()?.displayName ?? resolveProvider()?.displayName ?? "未配置" }

    func availableProviders() -> [(id: String, name: String)] {
        return CloudSpeechProviderRegistry.shared.allProviders().map {
            (id: $0.providerId, name: $0.displayName)
        }
    }
}
