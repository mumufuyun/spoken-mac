import Foundation
import Combine

struct ModeDefinition: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var sceneRules: String
    var builtin: WritingScene?

    var isCustom: Bool { builtin == nil }
    var icon: String { builtin?.settingsIcon ?? "slider.horizontal.3" }

    static func preset(_ scene: WritingScene) -> ModeDefinition {
        ModeDefinition(id: scene.storageID, name: scene.rawValue,
                       sceneRules: PromptComposer.defaultSceneRules(for: scene), builtin: scene)
    }
}

extension ModeDefinition {
    private enum CodingKeys: String, CodingKey { case id, name, sceneRules, builtin }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sceneRules = try container.decode(String.self, forKey: .sceneRules)
        let stored = try container.decodeIfPresent(String.self, forKey: .builtin)
        builtin = WritingScene.allCases.first {
            $0.storageID == stored || $0.rawValue == stored
                || (stored == LegacyPromptsV4.rawTranscriptName && $0 == .rawTranscript)
        }
        if stored != nil && builtin == nil {
            throw DecodingError.dataCorruptedError(forKey: .builtin, in: container, debugDescription: "Unknown built-in mode")
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sceneRules, forKey: .sceneRules)
        try container.encodeIfPresent(builtin?.storageID, forKey: .builtin)
    }
}

struct ModeConfiguration: Codable, Equatable {
    var version = 6
    var baseRules = PromptComposer.defaultBaseRules
    var modes = WritingScene.allCases.map(ModeDefinition.preset)
    var selectedID = WritingScene.rawTranscript.storageID
}

struct LegacyPromptBackup: Codable {
    var version = 1
    let createdAt: Date
    let templates: [String: String]
    let overrides: [String: String]
}

final class ModeStore: ObservableObject {
    static let shared = ModeStore()
    static let customLimit = 3
    @Published private(set) var configuration = ModeConfiguration()
    @Published private(set) var loadError: String?
    private let defaults: UserDefaults
    private let file: ConfigurationFile
    private let backupFile: ConfigurationFile

    init(defaults: UserDefaults = .standard,
         file: ConfigurationFile = .local("modes-v2"),
         backupFile: ConfigurationFile = .local("legacy-prompts-v1")) {
        self.defaults = defaults
        self.file = file
        self.backupFile = backupFile
        configuration.selectedID = legacySelection()
        reload()
    }

    var modes: [ModeDefinition] { configuration.modes }
    var customModes: [ModeDefinition] { modes.filter(\.isCustom) }
    var selected: ModeDefinition {
        modes.first { $0.id == configuration.selectedID } ?? .preset(.rawTranscript)
    }

    func reload() {
        do {
            if let saved = try file.read(ModeConfiguration.self) {
                if saved.version == 2 || saved.version == 3 || saved.version == 4 || saved.version == 5 {
                    var migrated = saved
                    if migrated.version == 2 { migrated = Self.migratingV2(migrated) }
                    if migrated.version == 3 { migrated = Self.migratingV3(migrated) }
                    if migrated.version == 4 { migrated = Self.migratingV4(migrated) }
                    if migrated.version == 5 { migrated = Self.migratingV5(migrated) }
                    try validate(migrated)
                    try file.save(migrated)
                    configuration = migrated
                } else {
                    try validate(saved)
                    configuration = saved
                }
            } else {
                // Never overwrite the original backup after a crash between backup and migration.
                if try backupFile.read(LegacyPromptBackup.self) == nil {
                    var templates: [String: String] = [:]
                    var overrides: [String: String] = [:]
                    for scene in WritingScene.allCases {
                        if let value = defaults.string(forKey: scene.promptUserDefaultsKey) {
                            overrides[scene.storageID] = value
                        }
                        templates[scene.storageID] = overrides[scene.storageID]
                            ?? AIProcessingService.defaultPrompt(for: scene)
                    }
                    try backupFile.save(LegacyPromptBackup(createdAt: Date(), templates: templates, overrides: overrides))
                }
                var initial = ModeConfiguration()
                initial.selectedID = legacySelection()
                try file.save(initial)
                configuration = initial
            }
            loadError = nil
        } catch {
            loadError = "模式配置未更新：\(error.localizedDescription)"
        }
    }

    func select(_ id: String) throws {
        guard modes.contains(where: { $0.id == id }) else { return }
        var next = configuration
        next.selectedID = id
        try commit(next)
    }

    func save(_ mode: ModeDefinition, baseRules: String) throws {
        var next = configuration
        var edited = mode
        edited.name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.sceneRules = mode.sceneRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if let builtin = edited.builtin { edited.name = builtin.rawValue }
        if let index = next.modes.firstIndex(where: { $0.id == mode.id }) {
            guard next.modes[index].builtin == mode.builtin else {
                throw ConfigurationError.invalid("不能修改模式类型")
            }
            next.modes[index] = edited
        } else {
            guard edited.isCustom, UUID(uuidString: edited.id) != nil else {
                throw ConfigurationError.invalid("自定义模式标识无效")
            }
            guard customModes.count < Self.customLimit else {
                throw ConfigurationError.invalid("最多可添加 \(Self.customLimit) 个自定义模式")
            }
            next.modes.append(edited)
        }
        next.baseRules = baseRules.trimmingCharacters(in: .whitespacesAndNewlines)
        try commit(next)
    }

    func delete(_ id: String) throws {
        guard modes.first(where: { $0.id == id })?.isCustom == true else {
            throw ConfigurationError.invalid("预设模式不能删除")
        }
        var next = configuration
        next.modes.removeAll { $0.id == id }
        if next.selectedID == id { next.selectedID = WritingScene.rawTranscript.storageID }
        try commit(next)
    }

    func draft(copying source: ModeDefinition? = nil) -> ModeDefinition {
        let stem = source.map { "\($0.name) 副本" } ?? "自定义模式"
        var name = stem
        var suffix = 2
        while modes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(stem) \(suffix)"
            suffix += 1
        }
        return ModeDefinition(id: UUID().uuidString, name: name,
                              sceneRules: source?.sceneRules ?? PromptComposer.defaultCustomRules)
    }

    func legacyPrompts() throws -> String {
        guard let backup = try backupFile.read(LegacyPromptBackup.self) else { return "暂无旧版 Prompt" }
        return WritingScene.allCases.map { scene in
            let changed = backup.overrides[scene.storageID] == nil ? "默认模板" : "曾修改"
            return "【\(scene.rawValue) · \(changed)】\n\(backup.templates[scene.storageID] ?? "")"
        }.joined(separator: "\n\n────────────\n\n")
    }

    private func commit(_ next: ModeConfiguration) throws {
        guard loadError == nil else { throw ConfigurationError.unavailable(loadError!) }
        try validate(next)
        try file.save(next)
        configuration = next
    }

    private func legacySelection() -> String {
        let raw = defaults.string(forKey: WritingScene.defaultsKey)
        if let scene = WritingScene.allCases.first(where: {
            $0.storageID == raw || $0.rawValue == raw
                || (raw == LegacyPromptsV4.rawTranscriptName && $0 == .rawTranscript)
        }) {
            return scene.storageID
        }
        switch defaults.string(forKey: "spokenMode") {
        case "润色": return WritingScene.casualChat.storageID
        case "摘要", "格式化": return WritingScene.meetingNotes.storageID
        case "Prompt": return WritingScene.workMessage.storageID
        default: return WritingScene.rawTranscript.storageID
        }
    }

    /// v2→v3：提示词整体迭代后，只刷新与旧默认值逐字一致（即从未被用户编辑过）的基础规则和内置场景规则。
    private static func migratingV2(_ saved: ModeConfiguration) -> ModeConfiguration {
        var next = saved
        next.version = 3
        if next.baseRules == LegacyPromptsV2.baseRules {
            next.baseRules = PromptComposer.defaultBaseRules
        }
        next.modes = next.modes.map { mode in
            guard let scene = mode.builtin, mode.sceneRules == LegacyPromptsV2.sceneRules(for: scene) else { return mode }
            var refreshed = mode
            refreshed.sceneRules = PromptComposer.defaultSceneRules(for: scene)
            return refreshed
        }
        return next
    }

    /// v3→v4：修复短输入过度解读的提示词迭代后，只刷新与 v3 默认值逐字一致（即从未被用户编辑过）的基础规则和内置场景规则。
    private static func migratingV3(_ saved: ModeConfiguration) -> ModeConfiguration {
        var next = saved
        next.version = 4
        if next.baseRules == LegacyPromptsV3.baseRules {
            next.baseRules = PromptComposer.defaultBaseRules
        }
        next.modes = next.modes.map { mode in
            guard let scene = mode.builtin, mode.sceneRules == LegacyPromptsV3.sceneRules(for: scene) else { return mode }
            var refreshed = mode
            refreshed.sceneRules = PromptComposer.defaultSceneRules(for: scene)
            return refreshed
        }
        return next
    }

    /// v4→v5："原样转写"更名为"流畅转写"并改为 AI 轻量整理后，刷新从未被用户编辑过的场景规则与内置名称。
    private static func migratingV4(_ saved: ModeConfiguration) -> ModeConfiguration {
        var next = saved
        next.version = 5
        next.modes = next.modes.map { mode in
            guard mode.builtin == .rawTranscript else { return mode }
            var refreshed = mode
            if refreshed.sceneRules == LegacyPromptsV4.rawTranscriptRules {
                refreshed.sceneRules = PromptComposer.defaultSceneRules(for: .rawTranscript)
            }
            if refreshed.name == LegacyPromptsV4.rawTranscriptName {
                refreshed.name = WritingScene.rawTranscript.rawValue
            }
            return refreshed
        }
        return next
    }

    /// v5→v6：忠实度迭代（隐性意向词保留、拼音缩写还原、会议进展归类、占位符禁止等）后，
    /// 只刷新与 v5 默认值逐字一致（即从未被用户编辑过）的基础规则和内置场景规则。
    private static func migratingV5(_ saved: ModeConfiguration) -> ModeConfiguration {
        var next = saved
        next.version = 6
        if next.baseRules == LegacyPromptsV5.baseRules {
            next.baseRules = PromptComposer.defaultBaseRules
        }
        next.modes = next.modes.map { mode in
            guard let scene = mode.builtin, mode.sceneRules == LegacyPromptsV5.sceneRules(for: scene) else { return mode }
            var refreshed = mode
            refreshed.sceneRules = PromptComposer.defaultSceneRules(for: scene)
            return refreshed
        }
        return next
    }

    private func validate(_ value: ModeConfiguration) throws {
        guard value.version == 6 else { throw ConfigurationError.invalid("模式配置版本不受支持，请保留原文件") }
        guard !value.baseRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalid("基础规则不能为空")
        }
        var ids = Set<String>()
        var names = Set<String>()
        for mode in value.modes {
            guard ids.insert(mode.id).inserted,
                  names.insert(mode.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted,
                  !mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !mode.sceneRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.invalid("模式名称不能重复，名称和场景规则不能为空")
            }
            guard mode.builtin.map({ $0.storageID == mode.id }) ?? (UUID(uuidString: mode.id) != nil) else {
                throw ConfigurationError.invalid("模式标识无效")
            }
        }
        guard WritingScene.allCases.allSatisfy({ scene in value.modes.contains { $0.builtin == scene } }),
              ids.contains(value.selectedID) else { throw ConfigurationError.invalid("模式配置缺少预设或当前选择") }
        // No read-time cap: a future version can raise the creation limit without losing existing modes.
    }
}
