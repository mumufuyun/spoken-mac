import AppKit
import Foundation

enum PersonalContextStore {
    static let contextKey = "personalContext"
    static let enabledKey = "personalContextEnabled"
}

enum WritingScene: String, CaseIterable, Codable, Identifiable {
    case rawTranscript = "原样转写"
    case casualChat = "日常聊天"
    case workMessage = "工作沟通"
    case formalDocument = "正式材料"
    case meetingNotes = "会议记录"
    case contentShare = "内容分享"
    case aiInstruction = "AI 指令"

    var id: Self { self }

    var requiresAI: Bool { self != .rawTranscript }

    var storageID: String {
        switch self {
        case .rawTranscript: return "raw_transcript"
        case .casualChat: return "casual_chat"
        case .workMessage: return "work_message"
        case .formalDocument: return "formal_document"
        case .meetingNotes: return "meeting_notes"
        case .contentShare: return "content_share"
        case .aiInstruction: return "ai_instruction"
        }
    }

    var promptUserDefaultsKey: String { "scene_prompt_\(storageID)" }

    var settingsIcon: String {
        switch self {
        case .rawTranscript: return "quote.bubble"
        case .casualChat: return "message"
        case .workMessage: return "briefcase"
        case .formalDocument: return "doc.text"
        case .meetingNotes: return "person.3"
        case .contentShare: return "megaphone"
        case .aiInstruction: return "sparkles"
        }
    }

    static let defaultsKey = "writingScene"

    static func load(from defaults: UserDefaults = .standard) -> WritingScene {
        if let stored = defaults.string(forKey: defaultsKey) {
            if let scene = allCases.first(where: { $0.storageID == stored }) {
                return scene
            }
            // 兼容旧版本以中文展示名称存储的值，并立即迁移为稳定标识。
            if let scene = WritingScene(rawValue: stored) {
                defaults.set(scene.storageID, forKey: defaultsKey)
                return scene
            }
        }

        // 从 2.0.6 的动作模式平滑迁移，避免升级后丢失用户选择。
        let legacy = defaults.string(forKey: "spokenMode") ?? "直接输入"
        let migrated: WritingScene
        switch legacy {
        case "润色": migrated = .casualChat
        case "摘要", "格式化": migrated = .meetingNotes
        case "Prompt": migrated = .workMessage
        case "翻译", "直接输入": migrated = .rawTranscript
        default: migrated = .workMessage
        }
        defaults.set(migrated.storageID, forKey: defaultsKey)
        // 旧版只有“翻译”模式才应迁移目标语言；其他模式升级后默认保留原语言。
        if legacy != "翻译" {
            defaults.set(TranslateLanguage.original.rawValue, forKey: "translateLang")
        }
        return migrated
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(storageID, forKey: Self.defaultsKey)
    }
}

/// 保留旧类型名作为源码迁移层，业务语义已经变为“使用场景”。
typealias SpokenMode = WritingScene

enum TranslateLanguage: String, CaseIterable, Codable {
    case original = "原语言"
    case english = "英文"
    case japanese = "日文"
    case korean = "韩文"
}

enum SceneSuggestionEngine {
    static func suggest(for app: NSRunningApplication?) -> WritingScene? {
        guard let app else { return nil }
        return suggest(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName)
    }

    static func suggest(bundleIdentifier: String?, localizedName: String?) -> WritingScene? {
        let bundle = (bundleIdentifier ?? "").lowercased()
        let name = (localizedName ?? "").lowercased()
        let identity = bundle + " " + name

        if containsAny(identity, [
            "chatgpt", "openai", "claude", "anthropic", "gemini", "perplexity",
            "poe", "copilot", "codex", "cursor", "windsurf", "豆包", "deepseek"
        ]) {
            return .aiInstruction
        }
        if containsAny(identity, ["wechat", "微信", "whatsapp", "telegram", "messages", "信息"]) {
            return .casualChat
        }
        if containsAny(identity, ["slack", "lark", "feishu", "飞书", "outlook", "mail", "邮箱", "teams"]) {
            return .workMessage
        }
        if containsAny(identity, ["zoom", "webex", "meeting", "腾讯会议"]) {
            return .meetingNotes
        }
        if containsAny(identity, ["pages", "word", "notion", "obsidian", "ulysses", "bear"]) {
            return .formalDocument
        }
        if containsAny(identity, ["weibo", "微博", "xiaohongshu", "小红书", "twitter", "threads"]) {
            return .contentShare
        }
        return nil
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }
}
