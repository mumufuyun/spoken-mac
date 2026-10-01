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
    case transportTimeout
    case sessionSetupTimeout
    case connectionFailed
    case recognitionStalled
    case apiError(String)
    case providerNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidURL: return "无效的 WebSocket URL"
        case .timeout: return "连接超时"
        case .transportTimeout: return "云端网络连接超时"
        case .sessionSetupTimeout: return "云端识别会话初始化超时"
        case .connectionFailed: return "连接失败"
        case .recognitionStalled: return "云端识别无响应"
        case .apiError(let msg): return "API 错误: \(msg)"
        case .providerNotFound(let id): return "未找到 Provider: \(id)"
        }
    }
}

// MARK: - CloudSpeechService 调度层

/// 按录音快照选择云端接口，隔离连接状态与迟到回调。
final class CloudSpeechService: NSObject, @unchecked Sendable {
    static let shared = CloudSpeechService()
    private let snapshotProvider: () throws -> SpeechSessionSnapshot
    private let factory: (SpeechSessionSnapshot) -> CloudSpeechProvider
    private let lock = NSRecursiveLock()
    private var current: CloudSpeechProvider?
    private var snapshot: SpeechSessionSnapshot?
    private var generation = UUID()
    private var recording = false
    private var pendingFinish: ((String?) -> Void)?
    var onConnected: (() -> Void)?
    @Published private(set) var connectionState: CloudConnectionState = .idle
    private(set) var lastHealthReport: CloudHealthReport?

    init(snapshotProvider: @escaping () throws -> SpeechSessionSnapshot = { try SpeechConnectionStore.shared.snapshot() },
         factory: @escaping (SpeechSessionSnapshot) -> CloudSpeechProvider = CloudSpeechService.makeProvider) {
        self.snapshotProvider = snapshotProvider; self.factory = factory
        super.init()
    }
    static func makeProvider(_ snapshot: SpeechSessionSnapshot) -> CloudSpeechProvider {
        switch snapshot.connection.api {
        case .qwenRealtime: return ReliableQwenSpeechProvider(snapshot: snapshot)
        case .iflytekRealtime, .volcengineStreaming: return StreamingSpeechProvider(snapshot: snapshot)
        case .openAITranscription: return HTTPTranscriptionProvider(snapshot: snapshot)
        }
    }
    private func matches(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == id }
    private func use(_ next: SpeechSessionSnapshot) -> CloudSpeechProvider {
        if let current, snapshot == next { return current }
        current?.disconnect(); generation = UUID()
        let provider = factory(next); current = provider; snapshot = next
        return provider
    }
    private func bind(_ provider: CloudSpeechProvider, id: UUID) {
        provider.onConnectionStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.matches(id) else { return }
                self.connectionState = state
                if state == .connected { self.onConnected?() }
            }
        }
    }
    func connect(snapshot supplied: SpeechSessionSnapshot? = nil, onPartial: @escaping (String) -> Void,
                 onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let next = try supplied ?? snapshotProvider()
            let provider = use(next); recording = true; generation = UUID(); let id = generation
            bind(provider, id: id)
            provider.connect(apiKey: next.credentials.apiKey, model: next.connection.model,
                onPartial: { [weak self] text in guard self?.matches(id) == true else { return }; onPartial(text) },
                onFinal: { [weak self] text in guard self?.matches(id) == true else { return }; onFinal(text) },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.lock.lock()
                    guard self.generation == id else { self.lock.unlock(); return }
                    let completion = self.pendingFinish; self.pendingFinish = nil; self.recording = false
                    self.lock.unlock()
                    // The caller may disconnect in onError. A stopped recording must still finish
                    // exactly once; its own session guard rejects a subsequently cancelled capture.
                    onError(error)
                    completion?(nil)
                })
        } catch { connectionState = .failed(error.localizedDescription); onError(error) }
    }
    func preconnect() {
        lock.lock(); defer { lock.unlock() }
        guard !recording else { return }
        do {
            let next = try snapshotProvider()
            let provider = use(next); bind(provider, id: generation)
            if next.connection.api == .qwenRealtime { provider.preconnect() }
        } catch { connectionState = .failed(error.localizedDescription) }
    }
    func sendAudio(_ data: Data) { lock.lock(); let provider = current; lock.unlock(); provider?.sendAudio(data) }
    func finish(completion: @escaping (String?) -> Void) {
        lock.lock()
        guard let provider = current, pendingFinish == nil else { lock.unlock(); completion(nil); return }
        let id = generation; pendingFinish = completion
        lock.unlock()
        provider.finish { [weak self] text in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == id else { self.lock.unlock(); return }
            let callback = self.pendingFinish; self.pendingFinish = nil; self.recording = false
            self.lock.unlock()
            callback?(text)
        }
    }
    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); pendingFinish = nil
        current?.disconnect(); current = nil; snapshot = nil; recording = false; connectionState = .idle
    }
    func performHealthCheck() -> CloudHealthReport {
        lock.lock(); defer { lock.unlock() }
        let report = CloudHealthReport(providerId: current?.providerId ?? "none", providerName: current?.displayName ?? "未配置",
            state: connectionState, isHealthy: current?.isReady ?? false,
            details: snapshot?.connection.api == .openAITranscription ? "结束录音后提交；尚未验证远端识别" : (current?.isReady == true ? "会话已就绪" : "未连接"))
        lastHealthReport = report; return report
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return current?.isReady ?? false }
    var currentProviderName: String { lock.lock(); defer { lock.unlock() }; return current?.displayName ?? "未配置" }
    func availableProviders() -> [(id: String, name: String)] { SpeechVendor.allCases.map { ($0.rawValue, $0.name) } }
}
