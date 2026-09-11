import Foundation
import Combine

enum ModelProvider: String, Codable, CaseIterable, Identifiable {
    case minimax, deepseek, zhipu, kimi, qwen, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .minimax: return "MiniMax"
        case .deepseek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .kimi: return "Kimi"
        case .qwen: return "千问"
        case .custom: return "自定义"
        }
    }
    var baseURL: String {
        switch self {
        case .minimax: return "https://api.minimax.cn/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .custom: return ""
        }
    }
    var models: [String] {
        switch self {
        case .minimax: return ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.7-highspeed", "MiniMax-M2.5", "MiniMax-M2.5-highspeed"]
        case .deepseek: return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .zhipu: return ["glm-4.7-flash", "glm-4.7"]
        case .kimi: return ["kimi-k2.6", "kimi-k2.5"]
        case .qwen: return ["qwen3.8-flash"]
        case .custom: return []
        }
    }
    var helpURL: URL {
        let value: String
        switch self {
        case .minimax: value = "https://platform.minimaxi.com/docs/api-reference/text-openai-api"
        case .deepseek: value = "https://api-docs.deepseek.com/"
        case .zhipu: value = "https://docs.bigmodel.cn/cn/guide/start/quick-start"
        case .kimi: value = "https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart"
        case .qwen: value = "https://help.aliyun.com/zh/model-studio/get-api-key"
        case .custom: value = "https://github.com/mumufuyun/spoken-mac"
        }
        return URL(string: value)!
    }
}

enum ModelAccess: String, Codable, CaseIterable {
    case api, tokenPlan
    var name: String { self == .api ? "普通 API" : "Token Plan 订阅" }
}

struct ModelConnection: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var provider: ModelProvider
    var access: ModelAccess = .api
    var baseURL: String
    var model: String
    var thinkingEnabled = false
    var credentialID: String?

    static func preset(_ provider: ModelProvider) -> ModelConnection {
        ModelConnection(name: provider.name, provider: provider, baseURL: provider.baseURL, model: provider.models.first ?? "")
    }
}

struct ConnectionConfiguration: Codable {
    var version = 1
    var connections: [ModelConnection] = []
    var activeID: String?
}

protocol ConnectionKeyStore {
    func readCredential(_ id: String) throws -> String?
    func writeCredential(_ key: String, id: String) throws
    func removeCredential(_ id: String) throws
    func readLegacyCredential() throws -> String?
}

final class ModelConnectionStore: ObservableObject {
    static let shared = ModelConnectionStore()
    @Published private(set) var configuration = ConnectionConfiguration()
    @Published private(set) var loadError: String?
    private let defaults: UserDefaults
    private let file: ConfigurationFile
    private let keys: ConnectionKeyStore

    init(defaults: UserDefaults = .standard,
         file: ConfigurationFile = .local("model-connections-v1"),
         keys: ConnectionKeyStore = SecureKeyStorage.shared) {
        self.defaults = defaults
        self.file = file
        self.keys = keys
        reload()
    }

    var connections: [ModelConnection] { configuration.connections }
    var active: ModelConnection? { connections.first { $0.id == configuration.activeID } }

    func reload() {
        do {
            if let value = try file.read(ConnectionConfiguration.self) {
                guard value.version == 1,
                      Set(value.connections.map(\.id)).count == value.connections.count,
                      value.activeID == nil || value.connections.contains(where: { $0.id == value.activeID }) else {
                    throw ConfigurationError.invalid("模型配置无效或版本不受支持，请保留原文件")
                }
                configuration = value
            } else {
                var migrated = legacyConfiguration()
                // A clean install has no reason to access Keychain until a connection is saved.
                if let index = migrated.connections.firstIndex(where: { $0.id == migrated.activeID }),
                   let oldKey = try keys.readLegacyCredential(), !oldKey.isEmpty {
                    let credentialID = UUID().uuidString
                    try keys.writeCredential(oldKey, id: credentialID)
                    migrated.connections[index].credentialID = credentialID
                    do { try file.save(migrated) }
                    catch { try? keys.removeCredential(credentialID); throw error }
                } else {
                    try file.save(migrated)
                }
                configuration = migrated
            }
            loadError = nil
        } catch { loadError = "模型配置未更新：\(error.localizedDescription)" }
    }

    func key(for connection: ModelConnection) throws -> String {
        guard let id = connection.credentialID else { return "" }
        return try keys.readCredential(id) ?? ""
    }

    func select(_ id: String?) throws {
        try ensureReady()
        guard id == nil || connections.contains(where: { $0.id == id }) else { return }
        var next = configuration
        next.activeID = id
        try file.save(next)
        configuration = next
    }

    @discardableResult
    func save(_ draft: ModelConnection, key: String, activate: Bool = false) throws -> ModelConnection {
        try ensureReady()
        var connection = draft
        connection.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(connection)
        guard !connections.contains(where: { $0.id != connection.id && $0.name.caseInsensitiveCompare(connection.name) == .orderedSame }) else {
            throw ConfigurationError.invalid("连接名称不能重复")
        }
        let oldCredential = connections.first(where: { $0.id == connection.id })?.credentialID
        // Stage a new credential, then atomically publish its reference. Failure leaves the old key intact.
        let newCredential = secret.isEmpty ? nil : UUID().uuidString
        if let id = newCredential { try keys.writeCredential(secret, id: id) }
        connection.credentialID = newCredential
        var next = configuration
        if let index = next.connections.firstIndex(where: { $0.id == connection.id }) { next.connections[index] = connection }
        else { next.connections.append(connection) }
        if activate || next.activeID == nil { next.activeID = connection.id }
        do { try file.save(next) }
        catch {
            if let id = newCredential { try? keys.removeCredential(id) }
            throw error
        }
        configuration = next
        if let id = oldCredential { try? keys.removeCredential(id) }
        return connection
    }

    func delete(_ id: String) throws {
        try ensureReady()
        let credential = connections.first(where: { $0.id == id })?.credentialID
        var next = configuration
        next.connections.removeAll { $0.id == id }
        if next.activeID == id { next.activeID = nil }
        try file.save(next)
        configuration = next
        if let credential { try? keys.removeCredential(credential) }
    }

    static func validate(_ connection: ModelConnection) throws {
        guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalid("连接名称和模型名称不能为空")
        }
        guard AIProcessingService.chatEndpoint(for: connection.baseURL) != nil else { throw MiniMaxError.invalidURL }
        guard connection.access == .api || connection.provider == .minimax else {
            throw ConfigurationError.invalid("此供应商仅提供普通 API 接入")
        }
    }

    private func ensureReady() throws {
        if let loadError { throw ConfigurationError.unavailable(loadError) }
    }

    private func legacyConfiguration() -> ConnectionConfiguration {
        let savedPreset = defaults.string(forKey: "llm_provider")
        let presetID = AIProcessingService.presets.contains(where: { $0.name == savedPreset }) ? savedPreset : "custom"
        let hasLegacy = savedPreset != nil || defaults.string(forKey: "llm_custom_base_url") != nil
            || defaults.string(forKey: "llm_custom_model") != nil
        guard hasLegacy else { return ConnectionConfiguration() }
        var result = ConnectionConfiguration()
        for preset in AIProcessingService.presets {
            let selected = preset.name == presetID
            let stored = defaults.dictionary(forKey: "llm_config_\(preset.name)") as? [String: String]
            let customURL = defaults.string(forKey: "llm_custom_base_url")
            guard selected || stored != nil || (preset.name == "custom" && customURL != nil) else { continue }
            let isCustom = preset.name == "custom"
            let fallback = AIProcessingService.presets[0]
            let baseURL = isCustom ? (customURL ?? fallback.baseURL) : (stored?["baseURL"] ?? preset.baseURL)
            let model = isCustom ? (defaults.string(forKey: "llm_custom_model") ?? fallback.model) : (stored?["model"] ?? preset.model)
            let provider: ModelProvider = isCustom ? .custom : (preset.name == "deepseek" ? .deepseek : .minimax)
            var connection = ModelConnection(name: preset.displayName, provider: provider, baseURL: baseURL, model: model)
            connection.thinkingEnabled = AIProcessingService.thinkingEnabled(in: defaults, model: model, baseURL: baseURL)
            result.connections.append(connection)
            if selected { result.activeID = connection.id }
        }
        return result
    }
}
