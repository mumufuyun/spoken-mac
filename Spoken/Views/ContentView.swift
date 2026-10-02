import SwiftUI

struct ContentView: View {
    let onOpenSettings: (SettingsSection) -> Void
    @ObservedObject var modes: ModeStore
    @ObservedObject var speechConnections: SpeechConnectionStore
    @ObservedObject private var activity = StateManager.shared
    @ObservedObject var connections: ModelConnectionStore
    @ObservedObject var hotkeys: HotKeyService
    @ObservedObject var accessibility: AccessibilityPermissionService
    @ObservedObject private var updates = AppUpdateService.shared
    @AppStorage("translateLang") private var language = TranslateLanguage.original.rawValue
    @State private var error: String?
    @State private var suggestion = ""
    private let heightOverride: CGFloat?

    init(onOpenSettings: @escaping (SettingsSection) -> Void, modes: ModeStore = .shared,
         connections: ModelConnectionStore = .shared, speechConnections: SpeechConnectionStore? = nil, hotkeys: HotKeyService? = nil, accessibility: AccessibilityPermissionService? = nil, defaults: UserDefaults = .standard, panelHeight: CGFloat? = nil) {
        self.onOpenSettings = onOpenSettings
        heightOverride = panelHeight
        _modes = ObservedObject(wrappedValue: modes)
        _connections = ObservedObject(wrappedValue: connections)
        _speechConnections = ObservedObject(wrappedValue: speechConnections ?? .shared)
        _hotkeys = ObservedObject(wrappedValue: hotkeys ?? .shared)
        _accessibility = ObservedObject(wrappedValue: accessibility ?? .shared)
        _language = AppStorage(wrappedValue: TranslateLanguage.original.rawValue, "translateLang", store: defaults)
    }

    private var compactHeight: Bool { (heightOverride ?? Self.panelHeight) < 400 }

    var body: some View {
        VStack(alignment: .leading, spacing: compactHeight ? 4 : 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spoken").font(.system(size: compactHeight ? 17 : 20, weight: .semibold, design: .rounded))
                    if !compactHeight { Text("把想法说出来").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if updates.availableVersion != nil {
                    Button { onOpenSettings(.updates) } label: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(SpokenTheme.accent)
                    }.buttonStyle(.plain).help("发现新版本，查看更新").accessibilityLabel("发现新版本，查看更新")
                }
                if accessibility.needsAttention && hotkeys.warning != nil {
                    Button { onOpenSettings(.permissions) } label: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    }.buttonStyle(.plain).help("自动输入未授权，点击完成辅助功能授权")
                        .accessibilityLabel("自动输入未授权，完成辅助功能授权")
                }
                Button { onOpenSettings(.shortcuts) } label: {
                    HStack(spacing: 4) {
                        if hotkeys.warning != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Text(hotkeys.displayName).font(.system(.caption, design: .monospaced))
                    }.padding(6).background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help("快捷键与操作 · " + hotkeys.statusText)
                    .accessibilityLabel("快捷键与操作：" + hotkeys.accessibilityName + "，" + hotkeys.statusText)
                Button(action: { onOpenSettings(.modes) }) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            }
            menuNotice
            ModeGrid(modes: modes.modes, selectedID: modes.selected.id, layout: compactHeight ? .dense : .compact,
                     onSelect: selectMode, onManage: { onOpenSettings(.modes) })
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 8) {
                connectionMenu("语音识别", name: speechConnections.engine == .local ? "本地识别" : (speechConnections.active?.name ?? "配置语音"), icon: "waveform") {
                    Picker("语音识别", selection: Binding(get: {
                        speechConnections.engine == .local ? "local" : (speechConnections.configuration.activeID ?? "local")
                    }, set: { id in
                        guard !activity.isBusy() else { return }
                        do {
                            try speechConnections.select(id == "local" ? speechConnections.configuration.activeID : id,
                                                         engine: id == "local" ? .local : (speechConnections.engine == .auto ? .auto : .cloud))
                            #if !SPOKEN_OFFLINE_TESTS
                            CloudSpeechService.shared.disconnect()
                            if id != "local" { SpeechService.shared.prepareCloudConnection() }
                            #endif
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    })) {
                        Text("本地识别").tag("local")
                        ForEach(speechConnections.connections) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("管理语音连接…") { onOpenSettings(.speech) }
                }.disabled(activity.isBusy())
                    .help("语音识别：" + (speechConnections.engine == .local ? "本地识别" : (speechConnections.active?.name ?? "尚未配置")))
                    .accessibilityLabel("切换语音识别")
                    .accessibilityValue(speechConnections.engine == .local ? "本地识别" : (speechConnections.active?.name ?? "尚未配置"))
                if connections.connections.isEmpty {
                    connectionCard("AI 模型") {
                        Button { onOpenSettings(.models) } label: {
                            Label("配置模型", systemImage: "cpu").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).foregroundStyle(SpokenTheme.accent).accessibilityLabel("配置 AI 模型")
                    }
                } else {
                    connectionMenu("AI 模型", name: connections.active?.name ?? "选择模型", icon: "cpu") {
                        Picker("AI 模型", selection: Binding(get: { connections.configuration.activeID ?? "" }, set: { value in
                            do { try connections.select(value.isEmpty ? nil : value); error = nil }
                            catch { self.error = error.localizedDescription }
                        })) {
                            Text("未选择").tag("")
                            ForEach(connections.connections) { Text($0.name + " · " + $0.model).tag($0.id) }
                        }.pickerStyle(.inline)
                        Divider()
                        Button("管理 AI 模型…") { onOpenSettings(.models) }
                    }
                        .help(connections.active.map { "AI 模型：" + $0.name + " · " + $0.model } ?? "选择 AI 模型")
                        .accessibilityLabel("切换 AI 模型")
                        .accessibilityValue(connections.active.map { $0.name + "，" + $0.model } ?? "尚未配置")
                }
            }
            HStack {
                Text("输出语言").foregroundStyle(.secondary)
                Picker("输出语言", selection: $language) {
                    ForEach(TranslateLanguage.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().frame(width: 125)
                Spacer()
                Button("检查更新", action: updates.checkForUpdates).buttonStyle(.plain)
                    .disabled(!updates.canCheckForUpdates || activity.isBusy() || updates.isInstalling || updates.isWaitingForIdle)
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }.font(.caption).controlSize(.small)
            if let message = error ?? modes.loadError ?? connections.loadError ?? speechConnections.loadError {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(compactHeight ? 1 : 2).help(message)
            } else if let active = connections.active, active.credentialID == nil {
                Button("当前连接缺少密钥，前往配置") { onOpenSettings(.models) }.font(.caption)
            } else if !compactHeight {
                Text(hotkeys.warning != nil ? "快捷键不可用，请先修改或重新检测" : (suggestion.isEmpty ? "回到输入框，按 \(hotkeys.displayName) 开始" : suggestion))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(suggestion)
            }
        }
        .padding(compactHeight ? 10 : 14).frame(width: 380, height: heightOverride ?? Self.panelHeight)
        .background(SpokenTheme.background).tint(SpokenTheme.accent)
        .onAppear {
            if let app = NSWorkspace.shared.frontmostApplication,
               let scene = SceneSuggestionEngine.suggest(for: app), scene != modes.selected.builtin {
                suggestion = "\(app.localizedName ?? "当前应用")建议使用「\(scene.rawValue)」"
            } else { suggestion = "" }
        }
    }

    @ViewBuilder private var menuNotice: some View {
        if hotkeys.warning != nil || accessibility.needsAttention || hotkeys.showsGuide {
            HStack(spacing: 6) {
                if let warning = hotkeys.warning {
                    Label("快捷键不可用", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).help(warning).accessibilityLabel(warning)
                    Spacer(minLength: 0)
                    Button("修改") { onOpenSettings(.shortcuts) }.accessibilityLabel("修改快捷键")
                    Button("重新检测") { hotkeys.recheck() }.disabled(hotkeys.isBusy)
                } else if accessibility.needsAttention {
                    Label("需手动粘贴", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                        .help(accessibility.state.statusText + "。完成后请按 Command V 手动粘贴。")
                    Spacer(minLength: 0)
                    Button("完成辅助功能授权") { onOpenSettings(.permissions) }
                } else {
                    Text("按 \(hotkeys.displayName) 开始 / 结束")
                        .help("回到目标输入框，按一次开始，再按一次结束。处理中按当前快捷键或 Esc 取消。")
                    Spacer(minLength: 0)
                    Button("操作说明") { onOpenSettings(.shortcuts) }
                    Button("知道了") { hotkeys.acknowledgeGuide() }
                }
            }.font(.caption).controlSize(.mini).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, compactHeight ? 4 : 8)
                .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func connectionMenu<Items: View>(_ title: String, name: String, icon: String,
                                             @ViewBuilder items: () -> Items) -> some View {
        connectionCard(title) {
            // AppKit flattens a Menu's label; keep the caption and card outside it.
            Menu(content: items) { Label(name, systemImage: icon).lineLimit(1).truncationMode(.tail) }
                .menuStyle(.borderlessButton)
        }
    }

    private func connectionCard<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !compactHeight { Text(title).font(.system(size: 10)).foregroundStyle(.secondary) }
            control().font(.system(size: 12)).frame(width: compactHeight ? 164 : 156, alignment: .leading)
        }.padding(compactHeight ? 6 : 8)
            .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 8))
    }

    static var panelHeight: CGFloat { min(440, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 70)) }
    private func selectMode(_ id: String) {
        do { try modes.select(id); error = nil } catch { self.error = error.localizedDescription }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case speech, models, modes, context, shortcuts, permissions, updates
    static let groups: [(title: String, sections: [SettingsSection])] = [
        ("识别与处理", [.speech, .models]),
        ("表达偏好", [.modes, .context]),
        ("操作与授权", [.shortcuts, .permissions, .updates])
    ]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modes: return "模式"
        case .models: return "AI 模型"
        case .shortcuts: return "快捷键与操作"
        case .permissions: return "权限与授权"
        case .speech: return "语音识别"
        case .context: return "个人背景"
        case .updates: return "软件更新"
        }
    }
    var icon: String {
        switch self {
        case .modes: return "square.grid.2x2"
        case .models: return "cpu"
        case .shortcuts: return "keyboard"
        case .permissions: return "hand.raised"
        case .speech: return "waveform"
        case .context: return "person.crop.circle"
        case .updates: return "arrow.down.circle"
        }
    }
    var detail: String {
        switch self {
        case .modes: return "让每一种表达，都有适合的处理方式。"
        case .models: return "保存常用连接，所有模式共用当前模型。"
        case .shortcuts: return "设置顺手的组合，随时开始表达。"
        case .permissions: return "确认自动输入权限，完成授权后即可直接填入输入框。"
        case .speech: return "选择适合你的语音识别方式。"
        case .context: return "补充常用术语和表达习惯，帮助 AI 更准确地整理你的话。"
        case .updates: return "获取新功能和修复，保留已有设置。"
        }
    }
}

struct SettingsView: View {
    @State private var section: SettingsSection = .modes
    @StateObject private var navigation = SettingsNavigationGuard()
    @ObservedObject var modes: ModeStore
    @ObservedObject var connections: ModelConnectionStore
    @ObservedObject var hotkeys: HotKeyService
    @ObservedObject var accessibility: AccessibilityPermissionService
    let defaults: UserDefaults
    let speechDependencies: SpeechSettingsDependencies
    let connectionTestService: AIProcessingService

    init(modes: ModeStore = .shared, connections: ModelConnectionStore = .shared, hotkeys: HotKeyService? = nil, accessibility: AccessibilityPermissionService? = nil, initialSection: SettingsSection = .modes,
         defaults: UserDefaults = .standard, speechDependencies: SpeechSettingsDependencies = .live,
         connectionTestService: AIProcessingService = AIProcessingService(recordsMetrics: false)) {
        _modes = ObservedObject(wrappedValue: modes)
        _connections = ObservedObject(wrappedValue: connections)
        _hotkeys = ObservedObject(wrappedValue: hotkeys ?? .shared)
        _accessibility = ObservedObject(wrappedValue: accessibility ?? .shared)
        self.defaults = defaults; self.speechDependencies = speechDependencies
        self.connectionTestService = connectionTestService
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spoken").font(.system(size: 23, weight: .semibold, design: .rounded))
                    .padding(.vertical, 24).padding(.horizontal, 10)
                ForEach(SettingsSection.groups, id: \.title) { group in
                    Text(group.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    ForEach(group.sections) { item in
                        Button {
                            if item != section && navigation.allowNavigation() { section = item }
                        } label: {
                            HStack(spacing: 6) {
                                Label(item.title, systemImage: item.icon).font(.system(size: 13, weight: .medium))
                                if item == .permissions && accessibility.needsAttention {
                                    Image(systemName: "exclamationmark.circle.fill").font(.caption)
                                        .foregroundStyle(.orange).accessibilityHidden(true)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(section == item ? SpokenTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityValue(section == item ? "已选择" : "")
                            .accessibilityLabel(item.title + (item == .permissions && accessibility.needsAttention ? "，待授权" : ""))
                    }
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
                    case .shortcuts: HotKeySettingsView(service: hotkeys, navigation: navigation)
                    case .permissions: AccessibilitySettingsView(service: accessibility, navigation: navigation)
                    case .speech: SpeechConfigSectionView(navigation: navigation, dependencies: speechDependencies).padding(24)
                    case .context: PersonalSettingsView(navigation: navigation, defaults: defaults)
                    case .updates: UpdateSettingsView(updates: .shared, navigation: navigation)
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

final class PersonalContextEditor: ObservableObject {
    @Published var profile: PersonalContextProfile
    @Published var enabled: Bool
    @Published private(set) var saved = false
    private var originalProfile: PersonalContextProfile
    private var originalEnabled: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let profile = PersonalContextStore.load(from: defaults)
        let enabled = defaults.object(forKey: PersonalContextStore.enabledKey) == nil
            || defaults.bool(forKey: PersonalContextStore.enabledKey)
        self.profile = profile; originalProfile = profile
        self.enabled = enabled; originalEnabled = enabled
    }

    var isDirty: Bool { profile != originalProfile || enabled != originalEnabled }

    func save() {
        PersonalContextStore.save(profile, enabled: enabled, to: defaults)
        originalProfile = profile; originalEnabled = enabled; saved = true
    }

    func discard() {
        profile = originalProfile; enabled = originalEnabled; saved = false
    }

    func clear() { profile = PersonalContextProfile(); saved = false }
}

struct PersonalSettingsView: View {
    let navigation: SettingsNavigationGuard
    @StateObject private var editor: PersonalContextEditor
    @State private var notesExpanded: Bool
    @State private var previewExpanded = false

    init(navigation: SettingsNavigationGuard, defaults: UserDefaults = .standard) {
        self.navigation = navigation
        let editor = PersonalContextEditor(defaults: defaults)
        _editor = StateObject(wrappedValue: editor)
        _notesExpanded = State(initialValue: !editor.profile.notes.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("在 AI 处理中使用个人背景", isOn: $editor.enabled)
                        Text(editor.enabled
                             ? "保存在本机；启用并保存后，会随需要 AI 处理的文本发送给当前模型服务商。"
                             : "保存后暂停使用，已填写的内容仍保留在本机。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("从容易识别错的词开始").font(.headline)
                        Text("每项写一两句即可，全部选填。只写与日常表达有关的信息，不必填写完整履历。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], spacing: 14) {
                        contextField("常用术语", icon: "textformat.abc",
                                     detail: "写正确名称和常见误识别，帮助 AI 结合语境纠错。",
                                     example: "例如：Spoken（语音输入工具），常被识别成“斯波肯”；API 保留大写。",
                                     text: $editor.profile.terms)
                        contextField("工作或专业领域", icon: "briefcase",
                                     detail: "写你从事的领域和常做的事，帮助 AI 理解专业含义。",
                                     example: "例如：我做软件产品设计，经常讨论用户访谈、交互和版本迭代。",
                                     text: $editor.profile.role)
                        contextField("沟通对象与用途", icon: "person.2",
                                     detail: "写通常给谁、用来做什么，帮助 AI 把握语气。",
                                     example: "例如：常给项目同事发进度消息，也会把口述整理成内部说明。",
                                     text: $editor.profile.audience)
                        contextField("表达偏好", icon: "text.alignleft",
                                     detail: "写具体习惯，例如句式、分段和要避免的表达。",
                                     example: "例如：用短句，有多个事项时分点；保留专业术语，不加客套结尾。",
                                     text: $editor.profile.style)
                    }
                    DisclosureGroup(isExpanded: $notesExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("补充其他与日常表达有关的信息。原有背景也保留在这里，可继续使用或自行分类。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            TextEditor(text: $editor.profile.notes)
                                .font(.system(size: 13)).scrollContentBackground(.hidden)
                                .padding(10).frame(height: 140)
                                .background(SpokenTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SpokenTheme.border))
                                .accessibilityLabel("其他补充，选填")
                        }.padding(.top, 10)
                    } label: {
                        Text(editor.profile.notes.isEmpty ? "其他补充（选填）" : "其他补充（含已填写内容）")
                            .font(.callout.weight(.medium))
                    }
                    Text("背景仅辅助理解，不用于补写事实；本次表达和所选模式的要求优先。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !editor.profile.isEmpty {
                        DisclosureGroup("查看已填写的背景", isExpanded: $previewExpanded) {
                            Text(editor.profile.promptText).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.callout)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("清空内容", action: editor.clear).disabled(editor.profile.isEmpty)
                Spacer()
                if editor.isDirty {
                    Text("未保存").font(.callout).foregroundStyle(.secondary)
                } else if editor.saved {
                    Text(editor.enabled ? "已保存，用于后续录音" : "已保存，已暂停使用背景")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("保存", action: editor.save)
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .onAppear {
            navigation.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard)
        }
    }

    private func contextField(_ title: String, icon: String, detail: String, example: String,
                              text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(title, text: text, prompt: Text(example).foregroundStyle(.secondary), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(3...5)
                .padding(10)
                .background(SpokenTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SpokenTheme.border))
                .accessibilityLabel(title + "，选填").accessibilityHint(detail + example)
                .help(example)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 12))
    }
}
