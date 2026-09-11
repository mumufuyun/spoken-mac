import SwiftUI

final class ConnectionEditor: ObservableObject {
    @Published var draft: ModelConnection
    @Published var key = ""
    @Published var error: String?
    @Published var message = ""
    @Published var keyLoadFailed = false
    @Published var testing = false
    private var original: ModelConnection
    private var originalKey = ""
    private var testID: UUID?
    private let testService: AIProcessingService
    let store: ModelConnectionStore

    init(store: ModelConnectionStore, testService: AIProcessingService = AIProcessingService(recordsMetrics: false)) {
        self.store = store
        self.testService = testService
        let initial = store.active ?? store.connections.first ?? .preset(.qwen)
        draft = initial; original = initial
    }
    var isNew: Bool { !store.connections.contains { $0.id == draft.id } }
    var isDirty: Bool { draft != original || key != originalKey }
    func load(_ connection: ModelConnection) {
        cancelTest()
        draft = connection; original = connection
        message = ""; error = nil; keyLoadFailed = false
        do { key = try store.key(for: connection); originalKey = key }
        catch { key = ""; originalKey = ""; keyLoadFailed = true; self.error = error.localizedDescription }
    }
    func create(_ provider: ModelProvider) {
        var connection = ModelConnection.preset(provider)
        var suffix = 2
        while store.connections.contains(where: { $0.name == connection.name }) {
            connection.name = "\(provider.name) \(suffix)"; suffix += 1
        }
        load(connection)
        original.name = "" // Treat a deliberately created connection as an unsaved draft.
    }
    func changeProvider(_ provider: ModelProvider) {
        cancelTest()
        if draft.name == draft.provider.name { draft.name = provider.name }
        draft.provider = provider; draft.access = .api
        draft.baseURL = provider.baseURL; draft.model = provider.models.first ?? ""
        draft.thinkingEnabled = false; draft.credentialID = nil
        key = ""; keyLoadFailed = false; message = ""
    }
    func changeAccess(_ access: ModelAccess) {
        guard draft.access != access else { return }
        draft.access = access
        draft.credentialID = nil
        key = ""; keyLoadFailed = false; message = ""
    }
    func save() throws {
        guard !keyLoadFailed else { throw ConfigurationError.unavailable("密钥读取失败，请先重试加载，避免覆盖原有密钥") }
        do { let saved = try store.save(draft, key: key); load(saved); message = "已保存" }
        catch { self.error = error.localizedDescription; throw error }
    }
    func retryKey() {
        do {
            key = try store.key(for: draft); originalKey = key
            keyLoadFailed = false; error = nil
        } catch { keyLoadFailed = true; self.error = error.localizedDescription }
    }
    func discard() { load(store.connections.first { $0.id == original.id } ?? store.active ?? store.connections.first ?? .preset(.qwen)) }
    func cancelTest() { testID = nil; testing = false; testService.cancelCurrentTask() }
    func test() {
        guard !keyLoadFailed else { return }
        do { try ModelConnectionStore.validate(draft) }
        catch { self.error = error.localizedDescription; return }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请先填写 API Key"; return }
        let id = UUID(); testID = id; testing = true; error = nil; message = ""
        let started = ProcessInfo.processInfo.systemUptime
        let mode = ModeDefinition(id: "connection-test", name: "测试连接", sceneRules: "仅回复 OK", builtin: .rawTranscript)
        var connection = draft
        connection.model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.baseURL = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = AIProcessingSnapshot(mode: mode, language: .english, systemPrompt: "仅回复 OK。",
                                            connection: connection, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
        testService.process(text: "连接测试，请回复 OK。", snapshot: snapshot) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.testID == id else { return }
                self.testing = false; self.testID = nil
                switch result {
                case .success: self.message = String(format: "连接通过 · %.2f 秒", ProcessInfo.processInfo.systemUptime - started)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var store: ModelConnectionStore
    let navigation: SettingsNavigationGuard
    @StateObject private var editor: ConnectionEditor
    @State private var advanced = false
    @State private var showDelete = false

    init(store: ModelConnectionStore, navigation: SettingsNavigationGuard,
         testService: AIProcessingService = AIProcessingService(recordsMetrics: false)) {
        self.store = store; self.navigation = navigation
        _editor = StateObject(wrappedValue: ConnectionEditor(store: store, testService: testService))
    }
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已保存的连接").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.connections) { connection in
                        Button {
                            if connection.id != editor.draft.id && navigation.allowNavigation() { editor.load(connection) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text(connection.name).lineLimit(1)
                                    if store.configuration.activeID == connection.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(SpokenTheme.accent) }
                                }.font(.callout)
                                Text(connection.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(editor.draft.id == connection.id ? SpokenTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help(connection.name + " · " + connection.model)
                    }
                    if editor.isNew { Text("新连接草稿").font(.caption).foregroundStyle(.secondary) }
                    Menu {
                        ForEach(ModelProvider.allCases) { provider in
                            Button(provider.name) { if navigation.allowNavigation() { editor.create(provider) } }
                        }
                    } label: { Label("添加连接", systemImage: "plus") }.padding(.top, 10)
                    Text("每个连接独立保存密钥，可添加同一家厂商的多个配置。")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                }.padding(16)
            }.frame(width: 180)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = store.loadError {
                        SettingsFeedback(error: error)
                        Button("重试加载") { store.reload(); editor.discard() }
                    }
                    Text(editor.isNew ? "添加模型连接" : editor.draft.name).font(.title2.bold())
                    field("连接名称", placeholder: "例如：千问 · 日常", text: $editor.draft.name)
                    Picker("供应商", selection: Binding(get: { editor.draft.provider }, set: editor.changeProvider)) {
                        ForEach(ModelProvider.allCases) { Text($0.name).tag($0) }
                    }
                    if editor.draft.provider == .minimax {
                        Picker("接入方式", selection: Binding(get: { editor.draft.access }, set: editor.changeAccess)) {
                            ForEach(ModelAccess.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                        }
                        Text(editor.draft.access == .api ? "使用普通 API Key，按量计费。" : "使用 Token Plan 专属 Key，不与普通 API Key 混用。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(editor.draft.provider == .custom ? "支持 OpenAI Chat Completions 兼容接口。" : "使用开放平台普通 API Key；此入口不抵扣 Coding Plan 订阅。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom) {
                        field("模型名称", placeholder: "填写模型 ID", text: $editor.draft.model)
                        if !editor.draft.provider.models.isEmpty {
                            Menu("预设") {
                                ForEach(editor.draft.provider.models, id: \.self) { model in Button(model) { editor.draft.model = model } }
                            }.frame(width: 70)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("API Key").font(.headline)
                            Spacer()
                            Link("获取密钥与接入说明", destination: editor.draft.access == .tokenPlan
                                 ? URL(string: "https://platform.minimaxi.com/docs/token-plan/intro")! : editor.draft.provider.helpURL).font(.caption)
                        }
                        SecureField("输入密钥，仅保存在本机钥匙串", text: $editor.key).textFieldStyle(.roundedBorder)
                        if editor.keyLoadFailed { Button("重试读取密钥", action: editor.retryKey) }
                    }
                    let adapter = ModelRequestAdapter(connection: editor.draft)
                    VStack(alignment: .leading, spacing: 6) {
                        if adapter.supportsThinkingToggle {
                            Toggle("开启思考", isOn: $editor.draft.thinkingEnabled).toggleStyle(.switch).controlSize(.small)
                        }
                        Text(adapter.thinkingDescription).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                    DisclosureGroup("高级设置 · API 地址", isExpanded: $advanced) {
                        field("Base URL", placeholder: "https://example.com/v1", text: $editor.draft.baseURL).padding(.top, 12)
                    }
                    if editor.draft.provider == .custom && !advanced {
                        Button("填写自定义 API 地址") { advanced = true }.font(.callout)
                    }
                    SettingsFeedback(error: editor.error, message: editor.message)
                    HStack {
                        if editor.testing {
                            ProgressView().controlSize(.small)
                            Button("取消测试") { editor.cancelTest() }
                        } else { Button("测试连接") { editor.test() }.disabled(editor.keyLoadFailed) }
                        Spacer()
                        Button("保存") { try? editor.save() }.buttonStyle(.borderedProminent)
                            .keyboardShortcut("s", modifiers: .command).disabled(editor.keyLoadFailed || store.loadError != nil)
                    }
                    Text("测试会发送一条固定短文本并产生少量调用用量，不包含语音或个人背景。测试不保存设置。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !editor.isNew {
                        Divider()
                        HStack {
                            Button("删除连接", role: .destructive) { showDelete = true }
                            Spacer()
                            if store.configuration.activeID == editor.draft.id { Label("当前使用", systemImage: "checkmark.circle").font(.callout) }
                            else {
                                Button("设为当前模型") {
                                    if navigation.allowNavigation() {
                                        do { try store.select(editor.draft.id) } catch { editor.error = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                }.padding(24)
            }
        }
        .onAppear {
            editor.load(editor.draft)
            navigation.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard)
        }
        .onDisappear { editor.cancelTest() }
        .onChange(of: editor.draft) { _, _ in editor.cancelTest(); if editor.isDirty { editor.message = "" } }
        .onChange(of: editor.key) { _, _ in editor.cancelTest(); if editor.isDirty { editor.message = "" } }
        .alert("删除「\(editor.draft.name)」？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do { try store.delete(editor.draft.id); editor.discard() } catch { editor.error = error.localizedDescription }
            }
        } message: { Text("同时移除此连接的密钥。若它是当前模型，需重新选择连接。已开始处理的录音不受影响。") }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}
