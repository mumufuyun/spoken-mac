import SwiftUI

final class ModeEditor: ObservableObject {
    @Published var draft: ModeDefinition
    @Published var baseRules: String
    @Published var error: String?
    @Published var saved = false
    private var original: ModeDefinition
    private var originalBase: String
    let store: ModeStore

    init(store: ModeStore) {
        self.store = store
        draft = store.selected; original = store.selected
        baseRules = store.configuration.baseRules; originalBase = store.configuration.baseRules
    }
    var isNew: Bool { !store.modes.contains { $0.id == draft.id } }
    var isDirty: Bool { isNew || draft != original || baseRules != originalBase }
    func load(_ mode: ModeDefinition) {
        draft = mode; original = mode
        baseRules = store.configuration.baseRules; originalBase = baseRules
        saved = false; error = nil
    }
    func save() throws {
        do {
            try store.save(draft, baseRules: baseRules)
            load(store.modes.first { $0.id == draft.id }!)
            saved = true
        } catch { self.error = error.localizedDescription; throw error }
    }
    func discard() { load(store.modes.first { $0.id == original.id } ?? store.selected) }
    func delete() throws {
        // Deleting one mode must not discard an unrelated edit to the global rules.
        let pendingBase = baseRules
        try store.delete(draft.id)
        load(store.selected)
        baseRules = pendingBase
    }
}

struct ModeSettingsView: View {
    @ObservedObject var store: ModeStore
    let navigation: SettingsNavigationGuard
    @StateObject private var editor: ModeEditor
    @State private var showDelete = false

    init(store: ModeStore, navigation: SettingsNavigationGuard) {
        self.store = store; self.navigation = navigation
        _editor = StateObject(wrappedValue: ModeEditor(store: store))
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("预设").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(store.modes.filter { !$0.isCustom }) { row($0) }
                    Text("自定义 \(store.customModes.count)/\(ModeStore.customLimit)")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 16)
                    ForEach(store.customModes) { row($0) }
                    if editor.isNew { row(editor.draft) }
                    Button { create(copy: false) } label: { Label("添加模式", systemImage: "plus") }
                        .padding(.top, 12).disabled(store.customModes.count >= ModeStore.customLimit || store.loadError != nil)
                    if store.customModes.count >= ModeStore.customLimit {
                        Text("已达上限，可编辑或删除现有模式。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }.padding(16)
            }.frame(width: 170)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = store.loadError {
                        SettingsFeedback(error: error)
                        Button("重试加载") { store.reload(); editor.load(store.selected) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(editor.draft.isCustom ? "自定义模式" : "预设模式", systemImage: editor.draft.icon)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if editor.isDirty { Text("未保存").font(.caption).foregroundStyle(.secondary) }
                        }
                        if editor.draft.isCustom {
                            TextField("模式名称", text: $editor.draft.name).font(.title2).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("模式名称")
                        } else { Text(editor.draft.name).font(.title2.bold()) }
                    }

                    if let scene = editor.draft.builtin {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(scene.settingsDescription)
                                .font(.callout).foregroundStyle(.secondary)
                            Text("菜单栏明确指定的输出语言优先于场景语言要求。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        RuleEditor(title: "场景规则", detail: "定义要完成的任务、语气和格式。例：回答语音中的问题，先给结论，再列出三个建议。无需填写文本占位符。", text: $editor.draft.sceneRules, minHeight: 250)
                        Text("菜单栏明确指定的输出语言优先于场景语言要求。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("恢复默认场景") { editor.draft.sceneRules = PromptComposer.defaultCustomRules }
                            Button("复制为新模式") { create(copy: true) }
                                .disabled(store.customModes.count >= ModeStore.customLimit)
                            Spacer()
                        }.controlSize(.small)
                        SettingsFeedback(error: editor.error, message: editor.saved && !editor.isDirty ? "已保存，用于后续录音" : "")
                        HStack {
                            if !editor.isNew {
                                Button("删除模式", role: .destructive) { showDelete = true }
                            }
                            Spacer()
                            Button("保存") { try? editor.save() }
                                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                                .disabled(store.loadError != nil)
                        }
                    }
                }.padding(24)
            }
        }
        .onAppear { navigation.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard) }
        .alert("删除「\(editor.draft.name)」？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do { try editor.delete() }
                catch { editor.error = error.localizedDescription }
            }
        } message: { Text("此模式将被移除。若正在使用它，会切回原样转写；已开始处理的录音不受影响。") }
    }

    private func row(_ mode: ModeDefinition) -> some View {
        Button {
            guard mode.id != editor.draft.id, navigation.allowNavigation() else { return }
            editor.load(mode)
        } label: {
            Label(mode.name, systemImage: mode.icon).font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(editor.draft.id == mode.id ? SpokenTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(mode.name).accessibilityValue(editor.draft.id == mode.id ? "正在编辑" : "")
    }

    private func create(copy: Bool) {
        guard navigation.allowNavigation() else { return }
        editor.load(store.draft(copying: copy ? editor.draft : nil))
    }
}
