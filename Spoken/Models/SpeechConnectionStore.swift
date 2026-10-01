import Foundation
import Combine

/// ASR protocols are distinct from LLM Chat Completions and from one another.
enum SpeechAPI: String, Codable, CaseIterable, Identifiable {
    case qwenRealtime, iflytekRealtime, volcengineStreaming, openAITranscription
    var id: String { rawValue }
    var name: String {
        switch self {
        case .qwenRealtime: return "千问 Realtime 兼容"
        case .iflytekRealtime: return "讯飞实时转写大模型"
        case .volcengineStreaming: return "豆包流式识别 V3"
        case .openAITranscription: return "OpenAI 音频转写兼容（结束后返回）"
        }
    }
    var endpoint: String {
        switch self {
        case .qwenRealtime: return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        case .iflytekRealtime: return "wss://office-api-ast-dx.iflyaisol.com/ast/communicate/v1"
        case .volcengineStreaming: return "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
        case .openAITranscription: return ""
        }
    }
    var model: String {
        switch self {
        case .qwenRealtime: return "qwen3-asr-flash-realtime"
        case .volcengineStreaming: return "volc.seedasr.sauc.duration"
        case .iflytekRealtime, .openAITranscription: return ""
        }
    }
}

enum SpeechVendor: String, Codable, CaseIterable, Identifiable {
    case qwen, iflytek, volcengine, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .qwen: return "千问"
        case .iflytek: return "讯飞"
        case .volcengine: return "豆包 · 火山引擎"
        case .custom: return "自定义"
        }
    }
    var api: SpeechAPI {
        switch self {
        case .qwen: return .qwenRealtime
        case .iflytek: return .iflytekRealtime
        case .volcengine: return .volcengineStreaming
        case .custom: return .openAITranscription
        }
    }
    var helpURL: URL {
        let value: String
        switch self {
        case .qwen: value = "https://help.aliyun.com/zh/model-studio/qwen-real-time-speech-recognition"
        case .iflytek: value = "https://www.xfyun.cn/doc/spark/asr_llm/rtasr_llm.html"
        case .volcengine: value = "https://www.volcengine.com/docs/6561/1354869"
        case .custom: value = "https://platform.openai.com/docs/api-reference/audio/createTranscription"
        }
        return URL(string: value)!
    }
}

struct SpeechCredentials: Codable, Equatable {
    var apiKey = ""
    var apiSecret = ""
}

struct SpeechConnection: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var vendor: SpeechVendor
    var api: SpeechAPI
    /// Complete endpoint, without credentials or generated signing query parameters.
    var endpoint: String
    var model: String
    var appID = ""
    var language = ""
    var credentialID: String?
    static func preset(_ vendor: SpeechVendor) -> Self {
        Self(name: vendor.name, vendor: vendor, api: vendor.api, endpoint: vendor.api.endpoint,
             model: vendor.api.model, language: vendor == .iflytek ? "autodialect" : "")
    }
}

struct SpeechConnectionConfiguration: Codable, Equatable {
    var version = 1
    var engine = SpeechRecognitionProvider.local.rawValue
    var connections: [SpeechConnection] = []
    var activeID: String?
}

struct SpeechSessionSnapshot: Equatable {
    let connection: SpeechConnection
    let credentials: SpeechCredentials
}

/// Separate namespace: an ASR connection can never borrow an LLM or another ASR key.
struct SpeechKeychain: ConnectionKeyStore {
    func readCredential(_ id: String) throws -> String? { try SecureKeyStorage.shared.readASRCredential(id) }
    func writeCredential(_ key: String, id: String) throws { try SecureKeyStorage.shared.writeASRCredential(key, id: id) }
    func removeCredential(_ id: String) throws { try SecureKeyStorage.shared.removeASRCredential(id) }
    func readLegacyCredential() throws -> String? { try SecureKeyStorage.shared.readSpeechCredential() }
    func readLegacyCredentialWithoutUI() throws -> String? { try SecureKeyStorage.shared.readSpeechCredential(allowInteraction: false) }
}

final class SpeechConnectionStore: ObservableObject {
    static let shared = SpeechConnectionStore()
    @Published private(set) var configuration = SpeechConnectionConfiguration()
    @Published private(set) var loadError: String?
    private let file: ConfigurationFile
    private let keys: ConnectionKeyStore
    private let defaults: UserDefaults
    init(file: ConfigurationFile = .local("speech-connections-v1"), keys: ConnectionKeyStore = SpeechKeychain(), defaults: UserDefaults = .standard) {
        self.file = file; self.keys = keys; self.defaults = defaults
        reload()
    }
    var connections: [SpeechConnection] { configuration.connections }
    var active: SpeechConnection? { connections.first { $0.id == configuration.activeID } }
    var engine: SpeechRecognitionProvider { SpeechRecognitionProvider(rawValue: configuration.engine) ?? .local }

    func reload(allowCredentialPrompt: Bool = false) {
        do {
            if let saved = try file.read(SpeechConnectionConfiguration.self) {
                guard saved.version == 1, SpeechRecognitionProvider(rawValue: saved.engine) != nil,
                      Set(saved.connections.map(\.id)).count == saved.connections.count,
                      saved.activeID == nil || saved.connections.contains(where: { $0.id == saved.activeID }) else {
                    throw ConfigurationError.invalid("语音连接配置无效，请保留原文件")
                }
                let references = saved.connections.compactMap(\.credentialID)
                guard Set(references).count == references.count else { throw ConfigurationError.invalid("语音连接不能共用密钥引用") }
                for connection in saved.connections { try Self.validate(connection) }
                configuration = saved
            } else {
                var migrated = SpeechConnectionConfiguration()
                migrated.engine = (SpeechRecognitionProvider(rawValue: defaults.string(forKey: "speechRecognitionProvider") ?? "") ?? .local).rawValue
                let hasLegacy = defaults.object(forKey: "cloud_speech_provider") != nil || defaults.object(forKey: "speech_model_name") != nil || migrated.engine != SpeechRecognitionProvider.local.rawValue
                var stagedKey: String?
                if hasLegacy {
                    let oldProvider = defaults.string(forKey: "cloud_speech_provider") ?? "qwen-realtime"
                    guard oldProvider == "qwen-realtime" || oldProvider == "dashscope" else {
                        throw ConfigurationError.invalid("旧云端供应商无法识别，原配置已保留，请检查后重试")
                    }
                    var connection = SpeechConnection.preset(.qwen)
                    connection.model = defaults.string(forKey: "speech_model_name") ?? connection.model
                    guard let endpoint = QwenEndpointResolver.webSocketURL(workspaceID: defaults.string(forKey: "speech_workspace_id"), model: connection.model) else {
                        throw ConfigurationError.invalid("旧语音地址无效，原配置已保留")
                    }
                    connection.endpoint = endpoint.absoluteString
                    try Self.validate(connection)
                    let oldKey = try allowCredentialPrompt ? keys.readLegacyCredential() : keys.readLegacyCredentialWithoutUI()
                    if let oldKey, !oldKey.isEmpty {
                        stagedKey = UUID().uuidString
                        try keys.writeCredential(Self.encode(SpeechCredentials(apiKey: oldKey)), id: stagedKey!)
                        connection.credentialID = stagedKey
                    }
                    migrated.connections = [connection]; migrated.activeID = connection.id
                }
                do { try file.save(migrated) }
                catch { if let stagedKey { try? keys.removeCredential(stagedKey) }; throw error }
                configuration = migrated
            }
            defaults.set(configuration.engine, forKey: "speechRecognitionProvider")
            loadError = nil
        } catch { loadError = "语音配置未更新：\(error.localizedDescription)" }
    }

    func credentials(for connection: SpeechConnection) throws -> SpeechCredentials {
        guard let id = connection.credentialID else { return SpeechCredentials() }
        guard let value = try keys.readCredential(id), let data = value.data(using: .utf8) else {
            throw ConfigurationError.unavailable("语音连接密钥不存在，请重新填写")
        }
        return try JSONDecoder().decode(SpeechCredentials.self, from: data)
    }
    func snapshot() throws -> SpeechSessionSnapshot {
        try ready()
        guard let active else { throw ConfigurationError.invalid("请先添加并选择云端语音连接") }
        let credentials = try credentials(for: active)
        try Self.validate(active, credentials: credentials)
        return SpeechSessionSnapshot(connection: active, credentials: credentials)
    }
    func select(_ id: String?, engine: SpeechRecognitionProvider? = nil) throws {
        try ready()
        guard id == nil || connections.contains(where: { $0.id == id }) else { throw ConfigurationError.invalid("语音连接不存在") }
        var next = configuration; next.activeID = id
        if let engine { next.engine = engine.rawValue }
        try file.save(next); configuration = next
        defaults.set(next.engine, forKey: "speechRecognitionProvider")
    }
    @discardableResult
    func save(_ draft: SpeechConnection, credentials: SpeechCredentials, engine: SpeechRecognitionProvider, activate: Bool = true) throws -> SpeechConnection {
        try ready()
        var connection = draft
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.appID = connection.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.language = connection.language.trimmingCharacters(in: .whitespacesAndNewlines)
        var credentials = credentials
        credentials.apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.apiSecret = credentials.apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(connection, credentials: credentials)
        guard !connections.contains(where: { $0.id != connection.id && $0.name.caseInsensitiveCompare(connection.name) == .orderedSame }) else {
            throw ConfigurationError.invalid("连接名称不能重复")
        }
        let oldKey = connections.first { $0.id == connection.id }?.credentialID
        let newKey = UUID().uuidString
        try keys.writeCredential(Self.encode(credentials), id: newKey)
        connection.credentialID = newKey
        var next = configuration
        if let index = next.connections.firstIndex(where: { $0.id == connection.id }) { next.connections[index] = connection }
        else { next.connections.append(connection) }
        if activate { next.activeID = connection.id }
        next.engine = engine.rawValue
        do { try file.save(next) } catch { try? keys.removeCredential(newKey); throw error }
        configuration = next; defaults.set(next.engine, forKey: "speechRecognitionProvider")
        if let oldKey { try? keys.removeCredential(oldKey) }
        return connection
    }
    func delete(_ id: String) throws {
        try ready()
        let credential = connections.first { $0.id == id }?.credentialID
        var next = configuration; next.connections.removeAll { $0.id == id }
        if next.activeID == id { next.activeID = nil; next.engine = SpeechRecognitionProvider.local.rawValue }
        try file.save(next); configuration = next; defaults.set(next.engine, forKey: "speechRecognitionProvider")
        if let credential { try? keys.removeCredential(credential) }
    }
    private func ready() throws { if let loadError { throw ConfigurationError.unavailable(loadError) } }
    private static func encode(_ credentials: SpeechCredentials) throws -> String { String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self) }
    static func validate(_ connection: SpeechConnection, credentials: SpeechCredentials? = nil) throws {
        guard UUID(uuidString: connection.id) != nil, !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalid("连接名称不能为空")
        }
        guard connection.vendor == .custom || connection.api == connection.vendor.api else { throw ConfigurationError.invalid("供应商和接口协议不匹配") }
        guard let url = URLComponents(string: connection.endpoint), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              (connection.api == .openAITranscription ? url.scheme == "https" : url.scheme == "wss") else {
            throw ConfigurationError.invalid("请填写完整的安全接口地址：流式接口使用 wss，音频转写使用 https")
        }
        let forbidden = ["key", "api_key", "apikey", "token", "authorization", "signature", "signa", "accesskeyid", "secret"]
        guard !(url.queryItems ?? []).contains(where: { forbidden.contains($0.name.lowercased()) }) else {
            throw ConfigurationError.invalid("请将密钥填写在专用字段，不要放入地址")
        }
        if connection.api != .iflytekRealtime && connection.model.isEmpty { throw ConfigurationError.invalid("模型或资源 ID 不能为空") }
        if connection.api == .iflytekRealtime && (connection.appID.isEmpty || !["autodialect", "autominor"].contains(connection.language)) {
            throw ConfigurationError.invalid("讯飞需要 App ID，并选择 autodialect 或 autominor 语种")
        }
        if let credentials {
            guard credentials.apiKey.rangeOfCharacter(from: .controlCharacters) == nil,
                  credentials.apiSecret.rangeOfCharacter(from: .controlCharacters) == nil,
                  connection.model.rangeOfCharacter(from: .controlCharacters) == nil else { throw ConfigurationError.invalid("密钥或模型字段不能包含换行等控制字符") }
            guard !credentials.apiKey.isEmpty else { throw ConfigurationError.invalid("请填写该连接的 API Key") }
            if connection.api == .iflytekRealtime && credentials.apiSecret.isEmpty { throw ConfigurationError.invalid("讯飞需要 API Secret") }
        }
    }
}
