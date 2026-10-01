import SwiftUI

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

struct SpeechSettingsDependencies {
    var defaults: UserDefaults
    var store: SpeechConnectionStore
    var refreshConnection: (SpeechRecognitionProvider) -> Void
    var isBusy: () -> Bool
    var metrics: () -> ASRMetricsSnapshot
    var latency: () -> [String: PipelineLatencyMetrics.Distribution]
    static var live: Self {
        Self(defaults: .standard, store: .shared, refreshConnection: { provider in
            CloudSpeechService.shared.disconnect()
            if provider != .local { SpeechService.shared.prepareCloudConnection() }
        }, isBusy: { MainActor.assumeIsolated { StateManager.shared.isBusy() } },
        metrics: { ASRStabilityMetrics.shared.snapshot() }, latency: { PipelineLatencyMetrics.shared.distributions() })
    }
}

final class SpeechConnectionEditor: ObservableObject {
    @Published var draft: SpeechConnection
    @Published var credentials = SpeechCredentials()
    @Published var engine: SpeechRecognitionProvider
    @Published var error: String?
    @Published var message = ""
    @Published var keyLoadFailed = false
    private var original: SpeechConnection
    private var originalCredentials = SpeechCredentials()
    private var originalEngine: SpeechRecognitionProvider
    let dependencies: SpeechSettingsDependencies
    var store: SpeechConnectionStore { dependencies.store }
    init(_ dependencies: SpeechSettingsDependencies) {
        self.dependencies = dependencies
        let initial = dependencies.store.active ?? dependencies.store.connections.first ?? .preset(.qwen)
        draft = initial; original = initial; engine = dependencies.store.engine; originalEngine = dependencies.store.engine
    }
    var isNew: Bool { !store.connections.contains { $0.id == draft.id } }
    var isDirty: Bool { original != draft || originalCredentials != credentials || originalEngine != engine }
    func load(_ connection: SpeechConnection) {
        draft = connection; original = connection; engine = store.engine; originalEngine = engine
        credentials = SpeechCredentials(); originalCredentials = credentials; keyLoadFailed = false; error = nil; message = ""
        do { credentials = try store.credentials(for: connection); originalCredentials = credentials }
        catch { keyLoadFailed = true; self.error = error.localizedDescription }
    }
    func retryCredentialRead() {
        do {
            let value = try store.credentials(for: original)
            credentials = value; originalCredentials = value; keyLoadFailed = false; error = nil
        } catch { keyLoadFailed = true; self.error = error.localizedDescription }
    }
    func create(_ vendor: SpeechVendor) {
        var connection = SpeechConnection.preset(vendor); var suffix = 2
        while store.connections.contains(where: { $0.name == connection.name }) { connection.name = "\(vendor.name) \(suffix)"; suffix += 1 }
        load(connection); original.name = ""; engine = .cloud
    }
    func changeAPI(_ api: SpeechAPI) {
        guard draft.api != api else { return }
        draft.api = api; draft.endpoint = api.endpoint; draft.model = api.model; draft.appID = ""
        draft.language = api == .iflytekRealtime ? "autodialect" : ""; draft.credentialID = nil
        credentials = SpeechCredentials(); keyLoadFailed = false; message = ""
    }
    func save() throws {
        guard !dependencies.isBusy() else { throw ConfigurationError.invalid("录音或处理期间不能修改语音连接") }
        guard !keyLoadFailed else { throw ConfigurationError.unavailable("请先重新读取密钥，避免覆盖有效配置") }
        do {
            if engine == .local && !isDirtyConnection {
                try store.select(store.configuration.activeID, engine: .local)
                originalEngine = engine
            } else {
                let saved = try store.save(draft, credentials: credentials, engine: engine)
                load(saved)
            }
            dependencies.refreshConnection(engine); error = nil; message = "已保存，下一次录音使用此配置"
        } catch { self.error = error.localizedDescription; throw error }
    }
    private var isDirtyConnection: Bool { original != draft || originalCredentials != credentials }
    func select(_ connection: SpeechConnection) throws {
        guard !dependencies.isBusy() else { throw ConfigurationError.invalid("录音或处理期间不能切换语音连接") }
        let nextEngine: SpeechRecognitionProvider = store.engine == .auto ? .auto : .cloud
        try store.select(connection.id, engine: nextEngine); load(connection); dependencies.refreshConnection(nextEngine)
    }
    func discard() { load(store.connections.first { $0.id == original.id } ?? store.active ?? .preset(.qwen)) }
    func delete() throws {
        guard !dependencies.isBusy() else { throw ConfigurationError.invalid("录音或处理期间不能删除语音连接") }
        try store.delete(draft.id); discard(); dependencies.refreshConnection(store.engine)
    }
}

struct SpeechConfigSectionView: View {
    let navigation: SettingsNavigationGuard
    let dependencies: SpeechSettingsDependencies
    @ObservedObject private var store: SpeechConnectionStore
    @ObservedObject private var activity = StateManager.shared
    @StateObject private var editor: SpeechConnectionEditor
    @State private var advanced = false
    @State private var showDelete = false
    @State private var showMetrics = false
    init(navigation: SettingsNavigationGuard, dependencies: SpeechSettingsDependencies = .live) {
        self.navigation = navigation; self.dependencies = dependencies; store = dependencies.store
        _editor = StateObject(wrappedValue: SpeechConnectionEditor(dependencies))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择识别方式，或添加常用供应商。语音连接与 AI 处理模型分别配置。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("识别方式", selection: $editor.engine) {
                ForEach(SpeechRecognitionProvider.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(activity.isBusy())
            if activity.isBusy() { Text("录音或处理期间暂不能切换或修改连接。").font(.caption).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已保存的连接").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.connections) { connection in
                            Button {
                                if navigation.allowNavigation() { editor.load(connection); advanced = connection.vendor == .custom }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(connection.name).lineLimit(1)
                                        Text(connection.vendor.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if store.configuration.activeID == connection.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(SpokenTheme.accent) }
                                }.padding(10).background(editor.draft.id == connection.id ? SpokenTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).help(connection.name)
                        }
                        Menu("添加连接") {
                            ForEach(SpeechVendor.allCases) { vendor in
                                Button(vendor.name) { if navigation.allowNavigation() { editor.create(vendor); advanced = vendor == .custom } }
                            }
                        }.disabled(activity.isBusy())
                        if store.connections.isEmpty { Text("选择供应商后填写凭据即可开始。同一家供应商可保存多组连接。").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.trailing, 16)
                }.frame(width: 170)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(editor.draft.vendor.name).font(.headline)
                            Spacer()
                            Link("接入说明 ↗", destination: editor.draft.vendor.helpURL).font(.callout)
                        }
                        field("连接名称", text: $editor.draft.name)
                        if editor.draft.vendor == .custom {
                            Picker("接口协议", selection: Binding(get: { editor.draft.api }, set: editor.changeAPI)) {
                                ForEach(SpeechAPI.allCases) { Text($0.name).tag($0) }
                            }
                            Text("仅支持所选协议的兼容接口。聊天模型接口或其他私有 ASR 协议不能只替换地址使用。").font(.caption).foregroundStyle(.secondary)
                        }
                        if editor.draft.api == .iflytekRealtime {
                            field("App ID", text: $editor.draft.appID)
                            field("语种（autodialect / autominor）", text: $editor.draft.language)
                            Text("填写“实时语音转写大模型”服务的凭据；普通听写密钥不通用。autominor 需单独开通。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            field(editor.draft.api == .volcengineStreaming ? "资源 ID" : "模型名称", text: $editor.draft.model)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("API Key").font(.callout)
                            SecureField("该语音服务的 API Key", text: $editor.credentials.apiKey).textFieldStyle(.roundedBorder).accessibilityLabel("语音连接 API Key")
                        }
                        if editor.draft.api == .iflytekRealtime {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Secret").font(.callout)
                                SecureField("该语音服务的 API Secret", text: $editor.credentials.apiSecret).textFieldStyle(.roundedBorder).accessibilityLabel("语音连接 API Secret")
                            }
                        }
                        if editor.draft.api == .volcengineStreaming {
                            Text("使用火山语音新版控制台的 API Key，与火山方舟聊天模型密钥不同。资源 ID 应与已开通的小时版或并发版一致。").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("高级设置 · 完整接口地址", isExpanded: $advanced) {
                            field("Endpoint", text: $editor.draft.endpoint).padding(.top, 8)
                            if editor.draft.api == .openAITranscription { field("识别语种（可留空）", text: $editor.draft.language) }
                        }
                        if editor.draft.api == .qwenRealtime {
                            Text("原业务空间地址会自动保留；使用专属域名时，可在高级设置填写完整 wss 地址。").font(.caption).foregroundStyle(.secondary)
                        }
                        if editor.draft.api == .openAITranscription {
                            Text("录音结束后上传并返回文字，不实时出字。填写完整 /audio/transcriptions 地址；单次音频最多 24 MB，请求最多等待 60 秒。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    }
                    Divider()
                    SettingsFeedback(error: editor.error ?? store.loadError, message: editor.isDirty ? "有未保存的修改" : editor.message)
                        if store.loadError != nil {
                            Button("重试读取旧配置与密钥") {
                                if navigation.allowNavigation() {
                                    store.reload(allowCredentialPrompt: true)
                                    if store.loadError == nil { editor.discard(); dependencies.refreshConnection(store.engine) }
                                }
                            }.help("解锁 Mac 后重试；系统可能请求允许 Spoken 访问旧密钥。原配置会保留，成功后才启用。")
                        }
                        if editor.keyLoadFailed { Button("重新读取密钥") { editor.retryCredentialRead() } }
                        HStack {
                            Button("保存并使用") { perform { try editor.save() } }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                                .disabled(editor.keyLoadFailed || store.loadError != nil)
                            if !editor.isNew && !editor.isDirty && store.configuration.activeID != editor.draft.id {
                                Button("立即切换") { perform { try editor.select(editor.draft) } }
                            }
                            Spacer()
                            if !editor.isNew { Button("删除", role: .destructive) { showDelete = true } }
                        }
                        Text(editor.engine == .auto ? "自动选择：云端不可用时尝试本地识别，不会自动换到其他云端供应商。" : "保存后生效；密钥仅存入本机钥匙串，不会与其他连接共用。")
                            .font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 20).disabled(activity.isBusy())
            }
            DisclosureGroup("稳定性记录", isExpanded: $showMetrics) {
                let metrics = dependencies.metrics()
                Text("会话 \(metrics.sessions) · 成功 \(metrics.successes) · 失败 \(metrics.failures) · 本地回退 \(metrics.fallbacks)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("历史统计主要来自千问链路；其他接口请以实际录音结果验收。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            editor.load(editor.draft)
            advanced = editor.draft.vendor == .custom
            navigation.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard)
        }
        .alert("删除此语音连接？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { perform { try editor.delete() } }
        } message: { Text("删除当前连接后将使用本地识别。其他连接不受影响。") }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { editor.error = error.localizedDescription } }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.callout); TextField(title, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title) }
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
