import SwiftUI

enum SpokenTheme {
    static let background = adaptive(light: "#FAF8F5", dark: "#211F1D")
    static let surface = adaptive(light: "#FFFFFF", dark: "#2C2926")
    static let inset = adaptive(light: "#F0ECE6", dark: "#37332E")
    static let accent = adaptive(light: "#85644B", dark: "#D6AD87")
    static let selectedText = adaptive(light: "#FFFFFF", dark: "#211F1D")
    static let border = adaptive(light: "#E1DBD2", dark: "#4D463E")

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

struct ModeGrid: View {
    let modes: [ModeDefinition]
    let selectedID: String
    var disabled = false
    var onSelect: (String) -> Void
    var onManage: (() -> Void)?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let raw = modes.first(where: { $0.builtin == .rawTranscript }) {
                modeButton(raw)
            }
            group("预设模式", modes: modes.filter { !$0.isCustom && $0.requiresAI })
            HStack {
                Text("自定义 · \(modes.filter(\.isCustom).count)/\(ModeStore.customLimit)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let onManage {
                    Button("管理模式", action: onManage).buttonStyle(.plain).font(.caption)
                        .foregroundStyle(SpokenTheme.accent)
                }
            }
            let custom = modes.filter(\.isCustom)
            if custom.isEmpty, let onManage {
                Button(action: onManage) {
                    Label("添加你的第一个模式", systemImage: "plus")
                        .font(.callout).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            } else if !custom.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) { ForEach(custom) { modeButton($0) } }
            }
        }
    }

    private func group(_ title: String, modes: [ModeDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) { ForEach(modes) { modeButton($0) } }
        }
    }

    private func modeButton(_ mode: ModeDefinition) -> some View {
        let selected = mode.id == selectedID
        return Button { onSelect(mode.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon).font(.system(size: 12))
                Text(mode.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 7)
            .foregroundStyle(selected ? SpokenTheme.selectedText : Color.primary)
            .background(selected ? SpokenTheme.accent : SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).help(mode.name)
        .accessibilityLabel(mode.name)
        .accessibilityValue(selected ? "已选择" : "未选择")
    }
}

struct RuleEditor: View {
    let title: String
    let detail: String
    @Binding var text: String
    var minHeight: CGFloat = 170
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(10).frame(minHeight: minHeight)
                .background(SpokenTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SpokenTheme.border))
                .accessibilityLabel(title)
        }
    }
}

struct SettingsFeedback: View {
    var error: String?
    var message = ""
    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else if !message.isEmpty {
            Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
        }
    }
}

/// Shared by section changes, row selection and window close. Drafts never silently disappear.
final class SettingsNavigationGuard: NSObject, ObservableObject, NSWindowDelegate {
    enum Decision { case save, discard, cancel }
    private var isDirty: () -> Bool = { false }
    private var save: () throws -> Void = {}
    private var discard: () -> Void = {}
    private var prepareNavigation: () -> Void = {}
    private let decision: () -> Decision
    private let reportFailure: (Error) -> Void

    init(decision: @escaping () -> Decision = SettingsNavigationGuard.askDecision,
         reportFailure: @escaping (Error) -> Void = SettingsNavigationGuard.showFailure) {
        self.decision = decision
        self.reportFailure = reportFailure
        super.init()
    }

    func install(isDirty: @escaping () -> Bool, save: @escaping () throws -> Void, discard: @escaping () -> Void,
                 prepareNavigation: @escaping () -> Void = {}) {
        self.isDirty = isDirty
        self.save = save
        self.discard = discard
        self.prepareNavigation = prepareNavigation
    }

    func allowNavigation() -> Bool {
        prepareNavigation()
        guard isDirty() else { return true }
        switch decision() {
        case .save:
            do { try save(); return true }
            catch { reportFailure(error); return false }
        case .discard: discard(); return true
        case .cancel: return false
        }
    }

    private static func askDecision() -> Decision {
        let alert = NSAlert()
        alert.messageText = "保存当前修改？"
        alert.informativeText = "保存后将用于后续录音。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private static func showFailure(_ error: Error) {
        let failure = NSAlert()
        failure.messageText = "未保存"
        failure.informativeText = error.localizedDescription
        failure.runModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { allowNavigation() }
}

struct SettingsWindowBinding: NSViewRepresentable {
    let navigation: SettingsNavigationGuard
    func makeNSView(context: Context) -> NSView { WindowView(navigation: navigation) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class WindowView: NSView {
        let navigation: SettingsNavigationGuard
        init(navigation: SettingsNavigationGuard) { self.navigation = navigation; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.delegate = navigation }
    }
}
