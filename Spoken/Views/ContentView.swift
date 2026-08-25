import SwiftUI
import CoreGraphics

struct ContentView: View {
    let onOpenSettings: () -> Void

    @State private var mode: SpokenMode = .workMessage
    @State private var translateLang: TranslateLanguage = .original
    @State private var statusMessage = "语言是最好的输入"

    // ElevenLabs Warm Palette
    private let textSecondary = Color(hex: "#4e4e4e")
    private let textMuted = Color(hex: "#777169")
    private let accentBlue = Color(hex: "#4a90d9")

    var body: some View {
        mainView
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Spoken")
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundColor(textSecondary)
                    .tracking(0.14)
                Spacer()
                Text("⌥+空格")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(textMuted)
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 使用场景 - 7 场景分两行
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach([SpokenMode.rawTranscript, .casualChat, .workMessage, .aiInstruction], id: \.self) { m in
                        ModeButton(mode: m, current: $mode)
                    }
                }
                HStack(spacing: 5) {
                    ForEach([SpokenMode.formalDocument, .meetingNotes, .contentShare], id: \.self) { m in
                        ModeButton(mode: m, current: $mode)
                    }
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 5) {
                Text("输出")
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
                ForEach(TranslateLanguage.allCases, id: \.self) { lang in
                    Button(action: {
                        translateLang = lang
                        UserDefaults.standard.set(lang.rawValue, forKey: "translateLang")
                    }) {
                        Text(lang.rawValue)
                            .font(.system(size: 10, weight: translateLang == lang ? .semibold : .regular))
                            .foregroundColor(translateLang == lang ? .white : textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(translateLang == lang ? accentBlue : Color(hex: "#f5f2ef"))
                            .cornerRadius(9999)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)

            Spacer().frame(height: 14)

            // 状态文字
            Text(statusMessage)
                .font(.system(size: 12, weight: .regular))
                .tracking(0.16)
                .foregroundColor(textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)

            Spacer().frame(height: 12)
        }
        .frame(width: 300, height: 205)
        .background(
            Color.white
                .shadow(color: Color(hex: "#4e3220").opacity(0.04), radius: 4, x: 0, y: 2)
                .shadow(color: Color(hex: "#000000").opacity(0.02), radius: 1, x: 0, y: 0)
        )
        .onAppear {
            mode = SpokenMode.load()
            let savedLang = UserDefaults.standard.string(forKey: "translateLang")
            if let rawValue = savedLang, let saved = TranslateLanguage(rawValue: rawValue) {
                translateLang = saved
            }
            if let app = NSWorkspace.shared.frontmostApplication,
               let suggestion = SceneSuggestionEngine.suggest(for: app),
               suggestion != mode {
                statusMessage = "\(app.localizedName ?? "当前应用")建议使用「\(suggestion.rawValue)」"
            }
        }
    }
}

// MARK: - 模式按钮

struct ModeButton: View {
    let mode: SpokenMode
    @Binding var current: SpokenMode

    private let warmStone = Color(hex: "#f5f2ef")
    private let textPrimary = Color(hex: "#000000")
    private let textSecondary = Color(hex: "#4e4e4e")

    var body: some View {
        Button(action: {
            current = mode
            mode.save()
        }) {
            Text(mode.rawValue)
                .font(.system(size: 11, weight: current == mode ? .semibold : .regular))
                .tracking(current == mode ? 0.3 : 0.14)
                .foregroundColor(current == mode ? .white : textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(current == mode ? textPrimary : warmStone)
                .cornerRadius(9999)
                .shadow(
                    color: Color(hex: "#4e3220").opacity(current == mode ? 0.12 : 0),
                    radius: 3, x: 0, y: 1
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

enum SettingsSection: String, CaseIterable, Identifiable {
    case modelConfig
    case speechConfig
    case personalContext
    case casualChat
    case workMessage
    case formalDocument
    case meetingNotes
    case contentShare
    case aiInstruction

    var id: Self { self }

    var title: String {
        switch self {
        case .modelConfig: return "AI 模型"
        case .speechConfig: return "语音识别"
        case .personalContext: return "个人背景"
        case .casualChat: return "日常沟通"
        case .workMessage: return "工作沟通"
        case .formalDocument: return "正式材料"
        case .meetingNotes: return "会议记录"
        case .contentShare: return "内容分享"
        case .aiInstruction: return "AI 指令"
        }
    }

    var description: String {
        switch self {
        case .modelConfig: return "配置转录后处理使用的模型服务、地址和访问密钥。"
        case .speechConfig: return "选择本地或云端识别，并查看云端稳定性与全流程延迟。"
        case .personalContext: return "提供长期背景和表达偏好，帮助 AI 更准确地理解术语与语境。"
        case .casualChat: return "调整微信、聊天等日常交流场景的文本整理方式。"
        case .workMessage: return "调整面向同事、管理层和合作方的工作沟通表达。"
        case .formalDocument: return "调整方案、汇报、复盘等正式工作材料的整理规则。"
        case .meetingNotes: return "调整会议口述、讨论纪要和行动信息的整理规则。"
        case .contentShare: return "调整自媒体、观点分享和公开内容的表达方式。"
        case .aiInstruction: return "将口述内容整理为清晰、可直接交给 AI 的指令。"
        }
    }

    var icon: String {
        switch self {
        case .modelConfig: return "cpu"
        case .speechConfig: return "waveform"
        case .personalContext: return "person.text.rectangle"
        case .casualChat: return SpokenMode.casualChat.settingsIcon
        case .workMessage: return SpokenMode.workMessage.settingsIcon
        case .formalDocument: return SpokenMode.formalDocument.settingsIcon
        case .meetingNotes: return SpokenMode.meetingNotes.settingsIcon
        case .contentShare: return SpokenMode.contentShare.settingsIcon
        case .aiInstruction: return SpokenMode.aiInstruction.settingsIcon
        }
    }

    var toSpokenMode: SpokenMode? {
        switch self {
        case .casualChat: return .casualChat
        case .workMessage: return .workMessage
        case .formalDocument: return .formalDocument
        case .meetingNotes: return .meetingNotes
        case .contentShare: return .contentShare
        case .aiInstruction: return .aiInstruction
        case .modelConfig, .speechConfig, .personalContext: return nil
        }
    }

    static let serviceSections: [SettingsSection] = [.speechConfig, .modelConfig]
    static let personalizationSections: [SettingsSection] = [.personalContext]
    static let sceneSections: [SettingsSection] = [
        .casualChat,
        .workMessage,
        .formalDocument,
        .meetingNotes,
        .contentShare,
        .aiInstruction
    ]
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .speechConfig
    @State private var apiKey: String = ""
    @State private var promptText: String = ""
    @State private var personalContextText: String = ""
    @State private var personalContextEnabled = true
    @State private var saved = false
    @State private var revertedToDefault = false
    
    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedSection: $selectedSection)

            Divider()

            VStack(spacing: 0) {
                SettingsPageHeader(section: selectedSection)

                Divider()

                settingsContent
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .frame(
            minWidth: 720,
            idealWidth: 860,
            maxWidth: .infinity,
            minHeight: 540,
            idealHeight: 650,
            maxHeight: .infinity
        )
        .onAppear {
            loadSectionData(selectedSection)
        }
        .onChange(of: selectedSection) { _, newSection in
            loadSectionData(newSection)
            saved = false
            revertedToDefault = false
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if selectedSection == .modelConfig {
            ModelConfigSectionView(apiKey: $apiKey, saved: $saved)
        } else if selectedSection == .speechConfig {
            SpeechConfigSectionView()
        } else if selectedSection == .personalContext {
            PersonalContextSectionView(
                contextText: $personalContextText,
                isEnabled: $personalContextEnabled,
                saved: $saved
            )
        } else {
            PromptSectionView(
                section: selectedSection,
                promptText: $promptText,
                saved: $saved,
                revertedToDefault: $revertedToDefault
            )
        }
    }
    
    private func loadSectionData(_ section: SettingsSection) {
        switch section {
        case .modelConfig:
            apiKey = SecureKeyStorage.shared.readAPIKey() ?? ""
        case .speechConfig:
            break
        case .personalContext:
            personalContextText = UserDefaults.standard.string(forKey: PersonalContextStore.contextKey) ?? ""
            personalContextEnabled = UserDefaults.standard.object(forKey: PersonalContextStore.enabledKey) == nil
                || UserDefaults.standard.bool(forKey: PersonalContextStore.enabledKey)
        case .casualChat, .workMessage, .formalDocument, .meetingNotes, .contentShare, .aiInstruction:
            if let mode = section.toSpokenMode {
                let custom = UserDefaults.standard.string(forKey: mode.promptUserDefaultsKey)
                if let c = custom, !c.isEmpty {
                    promptText = c
                } else {
                    promptText = MiniMaxService.defaultPrompt(for: mode)
                }
            }
        }
    }
}

struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 25))
                    .foregroundColor(Color(hex: "#4a90d9"))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Spoken")
                        .font(.system(size: 15, weight: .semibold))
                    Text("设置")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#777169"))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSidebarGroup(
                        title: "连接与服务",
                        sections: SettingsSection.serviceSections,
                        selectedSection: $selectedSection
                    )
                    SettingsSidebarGroup(
                        title: "个性化",
                        sections: SettingsSection.personalizationSections,
                        selectedSection: $selectedSection
                    )
                    SettingsSidebarGroup(
                        title: "AI 处理场景",
                        sections: SettingsSection.sceneSections,
                        selectedSection: $selectedSection
                    )
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
            }
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Color(hex: "#f5f2ef"))
    }
}

struct SettingsSidebarGroup: View {
    let title: String
    let sections: [SettingsSection]
    @Binding var selectedSection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.35)
                .foregroundColor(Color(hex: "#777169"))
                .padding(.horizontal, 9)
                .padding(.bottom, 2)

            ForEach(sections) { section in
                SettingsSidebarRow(
                    section: section,
                    isSelected: selectedSection == section,
                    action: { selectedSection = section }
                )
            }
        }
    }
}

struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)

                Text(section.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .foregroundColor(isSelected ? Color(hex: "#245f9e") : Color(hex: "#4e4e4e"))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.white : Color.clear)
                    .shadow(
                        color: Color.black.opacity(isSelected ? 0.05 : 0),
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct SettingsPageHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "#4a90d9"))
                Text(section.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Color(hex: "#000000"))
            }

            Text(section.description)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#777169"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 17)
        .background(Color.white)
    }
}

// MARK: - 个人背景

struct PersonalContextSectionView: View {
    @Binding var contextText: String
    @Binding var isEnabled: Bool
    @Binding var saved: Bool

    private let textPrimary = Color(hex: "#000000")
    private let textMuted = Color(hex: "#777169")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("个人背景")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textPrimary)
                Spacer()
                Toggle("启用", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text("用于术语消歧和表达风格适配。启用后会随需要 AI 后处理的转录一起发送给当前模型服务商；原样转写不会发送。")
                .font(.system(size: 10))
                .foregroundColor(textMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $contextText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textPrimary)
                .padding(8)
                .background(Color(hex: "#faf8f6"))
                .cornerRadius(6)
                .environment(\.colorScheme, .light)

            HStack {
                Button("清空") {
                    contextText = ""
                    UserDefaults.standard.removeObject(forKey: PersonalContextStore.contextKey)
                    saved = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#f5f2ef"))
                .foregroundColor(textPrimary)
                .cornerRadius(8)

                Button("保存") {
                    let value = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.isEmpty {
                        UserDefaults.standard.removeObject(forKey: PersonalContextStore.contextKey)
                    } else {
                        UserDefaults.standard.set(value, forKey: PersonalContextStore.contextKey)
                    }
                    UserDefaults.standard.set(isEnabled, forKey: PersonalContextStore.enabledKey)
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        saved = false
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#4a90d9"))
                .foregroundColor(.white)
                .cornerRadius(8)

                Spacer()
                if saved {
                    Text("已保存 ✓")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }
        }
    }
}

// MARK: - 模型配置区域

struct ModelConfigSectionView: View {
    @Binding var apiKey: String
    @Binding var saved: Bool
    
    @State private var selectedPreset: String = ""
    @State private var baseURL: String = ""
    @State private var modelName: String = ""
    
    private let textPrimary = Color(hex: "#000000")
    private let textMuted = Color(hex: "#777169")
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 提供商预设
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型提供商")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                    Text("选择预设配置，或选择「自定义」手动填写")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // 预设选择器
                FlowLayout(spacing: 8) {
                    ForEach(MiniMaxService.presets, id: \.name) { preset in
                        Button(action: {
                            selectPreset(preset)
                        }) {
                            Text(preset.displayName)
                                .font(.system(size: 11, weight: selectedPreset == preset.name ? .medium : .regular))
                                .foregroundColor(selectedPreset == preset.name ? .white : textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedPreset == preset.name ? Color(hex: "#4a90d9") : Color(hex: "#f5f2ef"))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Base URL
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textPrimary)
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: baseURL) { _, _ in
                            saveCurrentPresetConfig()
                        }
                }
                
                // 模型名
                VStack(alignment: .leading, spacing: 6) {
                    Text("模型名称")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textPrimary)
                    TextField("model-name", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: modelName) { _, _ in
                            saveCurrentPresetConfig()
                        }
                }
                
                // API Key
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textPrimary)
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                
                // 保存状态
                if saved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text("已保存")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                HStack(spacing: 12) {
                    Spacer()
                    Button("保存") {
                        saveConfig()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#4a90d9"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
        }
        .onAppear {
            loadCurrentConfig()
        }
    }
    
    private func selectPreset(_ preset: MiniMaxService.ProviderPreset) {
        // 切换前先保存当前配置
        saveCurrentPresetConfig()

        selectedPreset = preset.name
        if preset.name == "custom" {
            // 切到自定义时，恢复之前保存的自定义配置
            baseURL = UserDefaults.standard.string(forKey: "llm_custom_base_url") ?? ""
            modelName = UserDefaults.standard.string(forKey: "llm_custom_model") ?? ""
        } else {
            // 切到预设时，读取该预设的独立配置
            let configKey = "llm_config_\(preset.name)"
            if let savedConfig = UserDefaults.standard.dictionary(forKey: configKey) as? [String: String] {
                baseURL = savedConfig["baseURL"] ?? preset.baseURL
                modelName = savedConfig["model"] ?? preset.model
            } else {
                baseURL = preset.baseURL
                modelName = preset.model
            }
        }

        // 切换后立即保存新预设的默认配置，确保后续修改有地方存
        saveCurrentPresetConfig()
    }

    private func saveCurrentPresetConfig() {
        // 保存当前预设的配置到独立的 key
        let configKey = "llm_config_\(selectedPreset)"
        let config: [String: String] = [
            "baseURL": baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        UserDefaults.standard.set(config, forKey: configKey)

        // 同时保存当前选中的提供商
        UserDefaults.standard.set(selectedPreset, forKey: "llm_provider")
    }

    private func loadCurrentConfig() {
        let provider = UserDefaults.standard.string(forKey: "llm_provider") ?? MiniMaxService.presets[0].name
        selectedPreset = provider

        if provider == "custom" {
            baseURL = UserDefaults.standard.string(forKey: "llm_custom_base_url") ?? ""
            modelName = UserDefaults.standard.string(forKey: "llm_custom_model") ?? ""
        } else {
            let preset = MiniMaxService.presets.first { $0.name == provider }
            let configKey = "llm_config_\(provider)"
            if let savedConfig = UserDefaults.standard.dictionary(forKey: configKey) as? [String: String] {
                baseURL = savedConfig["baseURL"] ?? preset?.baseURL ?? ""
                modelName = savedConfig["model"] ?? preset?.model ?? ""
            } else {
                baseURL = preset?.baseURL ?? ""
                modelName = preset?.model ?? ""
            }
        }

        apiKey = SecureKeyStorage.shared.readAPIKey() ?? ""
    }

    private func saveConfig() {
        // 保存当前预设的独立配置
        let configKey = "llm_config_\(selectedPreset)"
        let config: [String: String] = [
            "baseURL": baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        UserDefaults.standard.set(config, forKey: configKey)

        // 保存当前选中的提供商
        UserDefaults.standard.set(selectedPreset, forKey: "llm_provider")

        // 保存自定义配置（兼容旧逻辑）
        if selectedPreset == "custom" {
            UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "llm_custom_base_url")
            UserDefaults.standard.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "llm_custom_model")
        }

        // 保存 API Key
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            _ = SecureKeyStorage.shared.saveAPIKey(trimmedKey)
        } else {
            SecureKeyStorage.shared.deleteAPIKey()
        }

        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            saved = false
        }
    }
}

// MARK: - Flow Layout（流式布局，用于预设按钮换行）

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

// MARK: - Prompt 编辑区域

struct PromptSectionView: View {
    let section: SettingsSection
    @Binding var promptText: String
    @Binding var saved: Bool
    @Binding var revertedToDefault: Bool
    
    private let textPrimary = Color(hex: "#000000")
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(section.title) Prompt")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textPrimary)
                Spacer()
                if let mode = section.toSpokenMode {
                    let hasCustom = UserDefaults.standard.string(forKey: mode.promptUserDefaultsKey) != nil
                    if hasCustom {
                        Text("自定义")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#4a90d9"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#4a90d9").opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
            .padding(.top, 8)
            
            Text("使用 {text} 作为内容占位符")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#999999"))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            TextEditor(text: $promptText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textPrimary)
                .padding(8)
                .background(Color(hex: "#faf8f6"))
                .cornerRadius(6)
                .environment(\.colorScheme, .light)
            
            HStack(spacing: 12) {
                Button("恢复默认") {
                    if let mode = section.toSpokenMode {
                        UserDefaults.standard.removeObject(forKey: mode.promptUserDefaultsKey)
                    }
                    revertedToDefault = true
                    saved = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        revertedToDefault = false
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#f5f2ef"))
                .foregroundColor(textPrimary)
                .cornerRadius(8)
                
                Button("保存") {
                    if let mode = section.toSpokenMode {
                        UserDefaults.standard.set(promptText, forKey: mode.promptUserDefaultsKey)
                    }
                    saved = true
                    revertedToDefault = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        saved = false
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#4a90d9"))
                .foregroundColor(.white)
                .cornerRadius(8)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Spacer()
                
                if saved {
                    Text("已保存 ✓")
                        .font(.system(size: 11))
                        .foregroundColor(Color.green)
                }
                if revertedToDefault {
                    Text("已恢复默认")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#4a90d9"))
                }
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - 语音配置区域

struct SpeechConfigSectionView: View {
    @State private var provider: SpeechRecognitionProvider = .local
    @State private var cloudProviderId: String = "dashscope"
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var saved: Bool = false
    @State private var metrics = ASRStabilityMetrics.shared.snapshot()
    @State private var latencyMetrics = PipelineLatencyMetrics.shared.distributions()

    private let textPrimary = Color(hex: "#000000")
    private let textMuted = Color(hex: "#777169")

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 识别引擎选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("识别引擎")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                    Text("选择语音识别方式")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 引擎选择器
                FlowLayout(spacing: 8) {
                    ForEach(SpeechRecognitionProvider.allCases, id: \.rawValue) { p in
                        Button(action: {
                            provider = p
                        }) {
                            Text(p.rawValue)
                                .font(.system(size: 11, weight: provider == p ? .medium : .regular))
                                .foregroundColor(provider == p ? .white : textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(provider == p ? Color(hex: "#4a90d9") : Color(hex: "#f5f2ef"))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 云端 Provider 选择
                if provider == .cloud || provider == .auto {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("云端服务")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(textPrimary)
                        Text("选择云端语音识别服务提供商")
                            .font(.system(size: 11))
                            .foregroundColor(textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    FlowLayout(spacing: 8) {
                        ForEach(availableCloudProviders(), id: \.id) { p in
                            Button(action: {
                                cloudProviderId = p.id
                            }) {
                                Text(p.name)
                                    .font(.system(size: 11, weight: cloudProviderId == p.id ? .medium : .regular))
                                    .foregroundColor(cloudProviderId == p.id ? .white : textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(cloudProviderId == p.id ? Color(hex: "#4a90d9") : Color(hex: "#f5f2ef"))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("云端模型")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textPrimary)
                        TextField(defaultModelPlaceholder(), text: $modelName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textPrimary)
                        SecureField("sk-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("稳定性记录")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button("刷新") {
                                metrics = ASRStabilityMetrics.shared.snapshot()
                                latencyMetrics = PipelineLatencyMetrics.shared.distributions()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#4a90d9"))
                        }
                        Text("会话 \(metrics.sessions) · 成功 \(metrics.successes) · 失败 \(metrics.failures) · 重连 \(metrics.reconnects) · 本地降级 \(metrics.fallbacks)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                        if metrics.successes + metrics.failures > 0 {
                            Text(String(format: "云端完成率 %.1f%%", metrics.successRate * 100))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(metrics.successRate >= 0.995 ? .green : .orange)
                        }
                        if !latencyMetrics.isEmpty {
                            Divider()
                            latencyRow("首字", key: "hotkey_to_first_text")
                            latencyRow("ASR收尾", key: "stop_to_asr_final")
                            latencyRow("AI处理", key: "ai_request_to_complete")
                            latencyRow("结束到写入", key: "stop_to_injection")
                        }
                        Text("仅保存在本机，不记录音频和转录正文。")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .background(Color(hex: "#f5f2ef"))
                    .cornerRadius(8)
                }

                // 保存状态
                if saved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text("已保存")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button("保存") {
                        saveConfig()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#4a90d9"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
        }
        .onAppear {
            loadConfig()
            metrics = ASRStabilityMetrics.shared.snapshot()
            latencyMetrics = PipelineLatencyMetrics.shared.distributions()
        }
    }

    @ViewBuilder
    private func latencyRow(_ label: String, key: String) -> some View {
        if let distribution = latencyMetrics[key] {
            Text("\(label) P50 \(milliseconds(distribution.p50))ms · P90 \(milliseconds(distribution.p90))ms · P95 \(milliseconds(distribution.p95))ms · n=\(distribution.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textMuted)
        }
    }

    private func milliseconds(_ seconds: Double) -> Int {
        Int((seconds * 1_000).rounded())
    }

    private func availableCloudProviders() -> [(id: String, name: String)] {
        CloudSpeechService.shared.availableProviders()
    }

    private func defaultModelPlaceholder() -> String {
        switch cloudProviderId {
        case "qwen-realtime":
            return "qwen3-asr-flash-realtime"
        default:
            return "fun-asr-flash-8k-realtime"
        }
    }

    private func loadConfig() {
        let rawValue = UserDefaults.standard.string(forKey: "speechRecognitionProvider") ?? SpeechRecognitionProvider.local.rawValue
        provider = SpeechRecognitionProvider(rawValue: rawValue) ?? .local
        cloudProviderId = UserDefaults.standard.string(forKey: "cloud_speech_provider") ?? "qwen-realtime"
        apiKey = SecureKeyStorage.shared.readSpeechAPIKey() ?? ""
        modelName = UserDefaults.standard.string(forKey: "speech_model_name") ?? defaultModelPlaceholder()
    }

    private func saveConfig() {
        UserDefaults.standard.set(provider.rawValue, forKey: "speechRecognitionProvider")
        UserDefaults.standard.set(cloudProviderId, forKey: "cloud_speech_provider")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            _ = SecureKeyStorage.shared.saveSpeechAPIKey(trimmedKey)
        } else {
            SecureKeyStorage.shared.deleteSpeechAPIKey()
        }
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(model.isEmpty ? defaultModelPlaceholder() : model, forKey: "speech_model_name")
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            saved = false
        }
    }
}

// MARK: - 颜色扩展

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
