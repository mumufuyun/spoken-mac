import SwiftUI

struct ContentView: View {
    let onOpenSettings: (SettingsSection) -> Void
    @ObservedObject var modes: ModeStore
    @ObservedObject var connections: ModelConnectionStore
    @AppStorage("translateLang") private var language = TranslateLanguage.original.rawValue
    @State private var error: String?
    @State private var suggestion = ""

    init(onOpenSettings: @escaping (SettingsSection) -> Void, modes: ModeStore = .shared,
         connections: ModelConnectionStore = .shared, defaults: UserDefaults = .standard) {
        self.onOpenSettings = onOpenSettings
        _modes = ObservedObject(wrappedValue: modes)
        _connections = ObservedObject(wrappedValue: connections)
        _language = AppStorage(wrappedValue: TranslateLanguage.original.rawValue, "translateLang", store: defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spoken").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("把想法说出来").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("⌥ 空格").font(.system(.caption, design: .monospaced))
                    .padding(6).background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 6))
                Button(action: { onOpenSettings(.modes) }) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            }
            ScrollView {
                ModeGrid(modes: modes.modes, selectedID: modes.selected.id, onSelect: selectMode,
                         onManage: { onOpenSettings(.modes) })
            }
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Text("AI 模型").foregroundStyle(.secondary)
                    Spacer()
                    if connections.connections.isEmpty {
                        Button("配置模型") { onOpenSettings(.models) }
                    } else {
                        Picker("AI 模型", selection: Binding(get: { connections.configuration.activeID ?? "" }, set: { value in
                            do { try connections.select(value.isEmpty ? nil : value); error = nil }
                            catch { self.error = error.localizedDescription }
                        })) {
                            Text("未选择").tag("")
                            ForEach(connections.connections) { Text($0.name + " · " + $0.model).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 245)
                    }
                }
                HStack {
                    Text("输出语言").foregroundStyle(.secondary)
                    Spacer()
                    Picker("输出语言", selection: $language) {
                        ForEach(TranslateLanguage.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 125)
                }
            }.font(.callout)
            if let message = error ?? modes.loadError ?? connections.loadError {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).help(message)
            } else if let active = connections.active, active.credentialID == nil {
                Button("当前连接缺少密钥，前往配置") { onOpenSettings(.models) }.font(.caption)
            }
            HStack {
                Text(suggestion.isEmpty ? "再次按快捷键完成输入" : suggestion)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(suggestion)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.caption)
            }
        }
        .padding(18).frame(width: 380, height: Self.panelHeight)
        .background(SpokenTheme.background).tint(SpokenTheme.accent)
        .onAppear {
            if let app = NSWorkspace.shared.frontmostApplication,
               let scene = SceneSuggestionEngine.suggest(for: app), scene != modes.selected.builtin {
                suggestion = "\(app.localizedName ?? "当前应用")建议使用「\(scene.rawValue)」"
            } else { suggestion = "" }
        }
    }

    static var panelHeight: CGFloat { min(480, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 70)) }
    private func selectMode(_ id: String) {
        do { try modes.select(id); error = nil } catch { self.error = error.localizedDescription }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case modes, models, speech, context
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modes: return "模式与提示词"
        case .models: return "AI 模型"
        case .speech: return "语音识别"
        case .context: return "个人背景"
        }
    }
    var icon: String {
        switch self {
        case .modes: return "square.grid.2x2"
        case .models: return "cpu"
        case .speech: return "waveform"
        case .context: return "person.crop.circle"
        }
    }
    var detail: String {
        switch self {
        case .modes: return "让每一种表达，都有适合的处理方式。"
        case .models: return "保存常用连接，所有模式共用当前模型。"
        case .speech: return "选择适合你的语音识别方式。"
        case .context: return "帮助模型理解你的术语和表达习惯。"
        }
    }
}

struct SettingsView: View {
    @State private var section: SettingsSection = .modes
    @StateObject private var navigation = SettingsNavigationGuard()
    @ObservedObject var modes: ModeStore
    @ObservedObject var connections: ModelConnectionStore
    let defaults: UserDefaults
    let speechDependencies: SpeechSettingsDependencies
    let connectionTestService: AIProcessingService

    init(modes: ModeStore = .shared, connections: ModelConnectionStore = .shared, initialSection: SettingsSection = .modes,
         defaults: UserDefaults = .standard, speechDependencies: SpeechSettingsDependencies = .live,
         connectionTestService: AIProcessingService = AIProcessingService(recordsMetrics: false)) {
        _modes = ObservedObject(wrappedValue: modes)
        _connections = ObservedObject(wrappedValue: connections)
        self.defaults = defaults; self.speechDependencies = speechDependencies
        self.connectionTestService = connectionTestService
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spoken").font(.system(size: 23, weight: .semibold, design: .rounded))
                    .padding(.vertical, 24).padding(.horizontal, 10)
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        if item != section && navigation.allowNavigation() { section = item }
                    } label: {
                        Label(item.title, systemImage: item.icon).font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(section == item ? SpokenTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityValue(section == item ? "已选择" : "")
                }
                Spacer()
                Text("语言是最好的输入").font(.caption).foregroundStyle(.secondary).padding(10)
            }.padding(12).frame(width: 178).background(SpokenTheme.inset.opacity(0.5))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.system(size: 24, weight: .semibold))
                    Text(section.detail).font(.callout).foregroundStyle(.secondary)
                }.padding(24)
                Divider()
                Group {
                    switch section {
                    case .modes: ModeSettingsView(store: modes, navigation: navigation)
                    case .models: ModelSettingsView(store: connections, navigation: navigation, testService: connectionTestService)
                    case .speech: SpeechConfigSectionView(navigation: navigation, dependencies: speechDependencies).padding(24)
                    case .context: PersonalSettingsView(navigation: navigation, defaults: defaults).padding(24)
                    }
                }.id(section)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 580, idealHeight: 740)
        .background(SpokenTheme.background).tint(SpokenTheme.accent)
        .background(SettingsWindowBinding(navigation: navigation))
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SpokenOpenSettingsSection"))) { notification in
            if let requested = notification.object as? SettingsSection, requested != section, navigation.allowNavigation() {
                section = requested
            }
        }
    }
}

struct PersonalSettingsView: View {
    let navigation: SettingsNavigationGuard
    var defaults: UserDefaults = .standard
    @State private var text = ""
    @State private var enabled = true
    @State private var originalText = ""
    @State private var originalEnabled = true
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("在 AI 处理中使用个人背景", isOn: $enabled)
            RuleEditor(title: "术语与表达偏好", detail: "启用后随需要 AI 处理的文本发送给当前模型。仅用于理解术语和语气，不补写事实。", text: $text)
            HStack {
                Button("清空") { text = ""; saved = false }
                Spacer()
                if saved { Text("已保存").font(.callout).foregroundStyle(.secondary) }
                Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear {
            load()
            navigation.install(isDirty: { text != originalText || enabled != originalEnabled }, save: save, discard: load)
        }
        .onChange(of: text) { _, _ in saved = false }
        .onChange(of: enabled) { _, _ in saved = false }
    }
    private func load() {
        text = defaults.string(forKey: PersonalContextStore.contextKey) ?? ""
        enabled = defaults.object(forKey: PersonalContextStore.enabledKey) == nil
            || defaults.bool(forKey: PersonalContextStore.enabledKey)
        originalText = text; originalEnabled = enabled
    }
    private func save() {
        defaults.set(text, forKey: PersonalContextStore.contextKey)
        defaults.set(enabled, forKey: PersonalContextStore.enabledKey)
        originalText = text; originalEnabled = enabled; saved = true
    }
}
