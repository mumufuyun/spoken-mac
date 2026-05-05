import SwiftUI
import CoreGraphics

enum SpokenMode: String, CaseIterable {
    case direct = "直接输入"
    case polish = "润色"
    case prompt = "Prompt"
    case translate = "翻译"
    case summarize = "摘要"
    case format = "格式化"
}

enum TranslateLanguage: String, CaseIterable {
    case english = "英文"
    case japanese = "日文"
    case korean = "韩文"
}

extension SpokenMode {
    var promptUserDefaultsKey: String {
        "prompt_custom_\(rawValue)"
    }
    
    var settingsIcon: String {
        switch self {
        case .direct: return "text.bubble"
        case .polish: return "wand.and.stars"
        case .prompt: return "terminal"
        case .translate: return "globe"
        case .summarize: return "doc.text"
        case .format: return "list.bullet"
        }
    }
}

struct ContentView: View {
    @State private var mode: SpokenMode = .direct
    @State private var translateLang: TranslateLanguage = .english
    @State private var statusMessage = "语言是最好的输入"
    @State private var showSettings = false

    // ElevenLabs Warm Palette
    private let textSecondary = Color(hex: "#4e4e4e")
    private let textMuted = Color(hex: "#777169")
    private let accentBlue = Color(hex: "#4a90d9")

    var body: some View {
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
                Button(action: { showSettings = true }) {
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

            // 模式切换 - 6模式分两行
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    ForEach([SpokenMode.direct, .polish, .prompt], id: \.self) { m in
                        ModeButton(mode: m, current: $mode)
                    }
                }
                HStack(spacing: 5) {
                    ForEach([SpokenMode.translate, .summarize, .format], id: \.self) { m in
                        ModeButton(mode: m, current: $mode)
                    }
                }
            }
            .padding(.horizontal, 12)

            // 翻译语言选择（翻译模式下显示）
            if mode == .translate {
                HStack(spacing: 8) {
                    Text("目标语言：")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(textMuted)
                    ForEach(TranslateLanguage.allCases, id: \.self) { lang in
                        Button(action: {
                            translateLang = lang
                            UserDefaults.standard.set(lang.rawValue, forKey: "translateLang")
                            UserDefaults.standard.synchronize()
                        }) {
                            Text(lang.rawValue)
                                .font(.system(size: 11, weight: translateLang == lang ? .medium : .regular))
                                .foregroundColor(translateLang == lang ? .white : textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(translateLang == lang ? accentBlue : Color(hex: "#f5f2ef"))
                                .cornerRadius(9999)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

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
        .frame(width: 260, height: mode == .translate ? 200 : 170)
        .background(
            Color.white
                .shadow(color: Color(hex: "#4e3220").opacity(0.04), radius: 4, x: 0, y: 2)
                .shadow(color: Color(hex: "#000000").opacity(0.02), radius: 1, x: 0, y: 0)
        )
        .onAppear {
            let savedMode = UserDefaults.standard.string(forKey: "spokenMode")
            if let rawValue = savedMode, let saved = SpokenMode(rawValue: rawValue) {
                mode = saved
            }
            let savedLang = UserDefaults.standard.string(forKey: "translateLang")
            if let rawValue = savedLang, let saved = TranslateLanguage(rawValue: rawValue) {
                translateLang = saved
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings)
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
            UserDefaults.standard.set(mode.rawValue, forKey: "spokenMode")
            UserDefaults.standard.synchronize()
            print("Spoken: [DEBUG] ModeButton: saved mode = \(mode.rawValue)")
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
    case apiKey
    case polish
    case prompt
    case translate
    case summarize
    case format
    
    var id: Self { self }
    
    var title: String {
        switch self {
        case .apiKey: return "API Key"
        case .polish: return "润色"
        case .prompt: return "Prompt"
        case .translate: return "翻译"
        case .summarize: return "摘要"
        case .format: return "格式化"
        }
    }
    
    var icon: String {
        switch self {
        case .apiKey: return "key.fill"
        case .polish: return "wand.and.stars"
        case .prompt: return "terminal"
        case .translate: return "globe"
        case .summarize: return "doc.text"
        case .format: return "list.bullet"
        }
    }
    
    var toSpokenMode: SpokenMode? {
        switch self {
        case .polish: return .polish
        case .prompt: return .prompt
        case .translate: return .translate
        case .summarize: return .summarize
        case .format: return .format
        case .apiKey: return nil
        }
    }
}

struct SettingsView: View {
    @Binding var isPresented: Bool
    @State private var selectedSection: SettingsSection = .apiKey
    @State private var apiKey: String = ""
    @State private var promptText: String = ""
    @State private var saved = false
    @State private var revertedToDefault = false
    
    private let textPrimary = Color(hex: "#000000")
    private let textSecondary = Color(hex: "#4a4a4a")
    private let textMuted = Color(hex: "#777169")
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航
            VStack(spacing: 0) {
                ForEach(SettingsSection.allCases) { section in
                    Button(action: {
                        selectedSection = section
                        loadSectionData(section)
                        saved = false
                        revertedToDefault = false
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 14))
                                .foregroundColor(selectedSection == section ? .white : textMuted)
                            Text(section.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(selectedSection == section ? .white : textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(selectedSection == section ? Color(hex: "#4a90d9") : Color.clear)
                }
                Spacer()
            }
            .frame(width: 130)
            .background(Color(hex: "#f5f2ef"))
            
            Divider()
            
            // 右侧内容区
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("设置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(textPrimary)
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(textMuted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .padding(.bottom, 8)
                
                Divider()
                    .padding(.horizontal, 16)
                
                // 内容
                if selectedSection == .apiKey {
                    APIKeySectionView(apiKey: $apiKey, saved: $saved)
                } else {
                    PromptSectionView(
                        section: selectedSection,
                        promptText: $promptText,
                        saved: $saved,
                        revertedToDefault: $revertedToDefault
                    )
                }
            }
            .frame(minWidth: 380)
            .padding(.top, 8)
        }
        .frame(width: 510, height: 380)
        .background(Color.white)
        .cornerRadius(12)
        .onAppear {
            loadSectionData(selectedSection)
        }
    }
    
    private func loadSectionData(_ section: SettingsSection) {
        switch section {
        case .apiKey:
            apiKey = SecureKeyStorage.shared.readAPIKey() ?? ""
        case .polish, .prompt, .translate, .summarize, .format:
            if let mode = section.toSpokenMode {
                let custom = UserDefaults.standard.string(forKey: mode.promptUserDefaultsKey)
                if let c = custom, !c.isEmpty {
                    promptText = c
                } else {
                    switch mode {
                    case .polish: promptText = MiniMaxService.defaultPolishPrompt
                    case .prompt: promptText = MiniMaxService.defaultPromptPrompt
                    case .translate: promptText = MiniMaxService.defaultTranslatePrompt(langName: "英文")
                    case .summarize: promptText = MiniMaxService.defaultSummarizePrompt
                    case .format: promptText = MiniMaxService.defaultFormatPrompt
                    default: promptText = ""
                    }
                }
            }
        }
    }
}

// MARK: - API Key 区域

struct APIKeySectionView: View {
    @Binding var apiKey: String
    @Binding var saved: Bool
    
    private let textPrimary = Color(hex: "#000000")
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MiniMax API Key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textPrimary)
                Text("用于调用 AI 处理服务，Key 会安全存储在系统 Keychain 中")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#999999"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            TextField("请输入 MiniMax API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            
            if saved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("已保存")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color.green)
            }
            
            HStack(spacing: 12) {
                Spacer()
                Button("保存") {
                    SecureKeyStorage.shared.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        saved = false
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(hex: "#4a90d9"))
                .foregroundColor(.white)
                .cornerRadius(8)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
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
            .padding(.horizontal, 20)
            .padding(.top, 8)
            
            Text("使用 {text} 作为内容占位符")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#999999"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            
            TextEditor(text: $promptText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textPrimary)
                .padding(8)
                .background(Color(hex: "#faf8f6"))
                .cornerRadius(6)
                .padding(.horizontal, 20)
            
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
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }
}
