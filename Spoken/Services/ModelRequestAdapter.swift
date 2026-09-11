import Foundation

struct ModelRequestAdapter {
    enum Thinking { case qwen, standard, minimaxM3, alwaysOn, providerDefault }
    let thinking: Thinking
    let outputTokenField: String
    let outputLimit: Int
    let usesQwenTemperature: Bool
    let splitReasoning: Bool

    init(connection: ModelConnection) {
        let host = URL(string: connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        let model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let qwenHost = host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" || host.hasSuffix(".maas.aliyuncs.com")
        let minimaxHost = ["api.minimax.cn", "api.minimax.chat", "api.minimaxi.com", "api.minimax.io"].contains(host)
        if qwenHost && (model == "qwen3.8-flash" || model.hasPrefix("deepseek-v4-")) {
            thinking = .qwen
        } else if minimaxHost && model == "minimax-m3" {
            thinking = .minimaxM3
        } else if minimaxHost && model.hasPrefix("minimax-m2") {
            thinking = .alwaysOn
        } else if (host == "api.deepseek.com" && model.hasPrefix("deepseek-v4-"))
                    || (host == "open.bigmodel.cn" && (model.hasPrefix("glm-4.7") || model.hasPrefix("glm-5")))
                    || (host == "api.moonshot.cn" && ["kimi-k2.5", "kimi-k2.6"].contains(model)) {
            thinking = .standard
        } else { thinking = .providerDefault }
        outputTokenField = minimaxHost && model == "minimax-m3" ? "max_completion_tokens" : "max_tokens"
        outputLimit = 16_384
        usesQwenTemperature = qwenHost
        splitReasoning = minimaxHost
    }

    var supportsThinkingToggle: Bool {
        switch thinking { case .qwen, .standard, .minimaxM3: return true; default: return false }
    }
    var thinkingDescription: String {
        switch thinking {
        case .alwaysOn: return "此模型始终开启思考，无法关闭"
        case .providerDefault: return "使用供应商默认参数；未确认此模型的思考开关"
        default: return "关闭可减少等待；复杂任务可按需开启"
        }
    }
    func usesThinking(_ requested: Bool) -> Bool {
        switch thinking { case .alwaysOn: return true; case .providerDefault: return false; default: return requested }
    }
    func parameters(thinkingEnabled: Bool, outputTokens: Int) -> [String: Any] {
        var body: [String: Any] = [outputTokenField: min(outputLimit, outputTokens)]
        if usesQwenTemperature { body["temperature"] = 0.0 }
        if splitReasoning { body["reasoning_split"] = true }
        switch thinking {
        case .qwen: body["enable_thinking"] = thinkingEnabled
        case .standard: body["thinking"] = ["type": thinkingEnabled ? "enabled" : "disabled"]
        case .minimaxM3: body["thinking"] = ["type": thinkingEnabled ? "adaptive" : "disabled"]
        case .alwaysOn, .providerDefault: break
        }
        return body
    }
}

/// Captured at the recording boundary, before ASR finalization or any subsequent settings edits.
struct AIProcessingSnapshot {
    let mode: ModeDefinition
    let language: TranslateLanguage
    let systemPrompt: String
    let connection: ModelConnection?
    let apiKey: String
    var requiresAI: Bool { mode.requiresAI || language != .original }

    static func capture(modes: ModeStore, connections: ModelConnectionStore,
                        defaults: UserDefaults = .standard) throws -> AIProcessingSnapshot {
        let mode = modes.selected
        let language = TranslateLanguage(rawValue: defaults.string(forKey: "translateLang") ?? "") ?? .original
        if !mode.requiresAI && language == .original {
            return AIProcessingSnapshot(mode: mode, language: language, systemPrompt: "", connection: nil, apiKey: "")
        }
        if let error = modes.loadError ?? connections.loadError { throw ConfigurationError.unavailable(error) }
        let enabled = defaults.object(forKey: PersonalContextStore.enabledKey) == nil || defaults.bool(forKey: PersonalContextStore.enabledKey)
        let prompt = PromptComposer.systemPrompt(mode: mode, baseRules: modes.configuration.baseRules,
                                                language: language, personalContext: enabled ? defaults.string(forKey: PersonalContextStore.contextKey) : nil)
        guard let connection = connections.active else { throw MiniMaxError.missingAPIKey }
        return AIProcessingSnapshot(mode: mode, language: language, systemPrompt: prompt,
                                    connection: connection, apiKey: try connections.key(for: connection))
    }
}
