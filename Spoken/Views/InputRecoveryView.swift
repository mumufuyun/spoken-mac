import SwiftUI

/// A key-capable nonactivating panel permits text selection without activating Spoken.
final class InputRecoveryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func fitContent(_ size: NSSize, on screen: NSScreen?) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        if let screen {
            setFrame(FloatingInputPanelLayout.frame(for: size, in: screen.visibleFrame), display: true)
        } else {
            setContentSize(size)
        }
    }
}

struct InputRecoveryView: View {
    static let width: CGFloat = 420
    @ObservedObject var recovery: InputRecoveryStore
    @ObservedObject private var modes: ModeStore
    var onSizeChange: (NSSize) -> Void
    var onClose: () -> Void

    init(recovery: InputRecoveryStore, onSizeChange: @escaping (NSSize) -> Void = { _ in }, onClose: @escaping () -> Void) {
        self.recovery = recovery
        _modes = ObservedObject(wrappedValue: recovery.modes)
        self.onSizeChange = onSizeChange
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("找回上次输入").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").foregroundStyle(.secondary).frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain).accessibilityLabel("关闭找回页面").help("关闭 · Esc")
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(recovery.display == .original ? "识别原文" : "整理结果")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if recovery.result != nil {
                        Picker("查看内容", selection: $recovery.display) {
                            ForEach(InputRecoveryStore.Display.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 158)
                    }
                }.frame(height: 20)
                if recovery.entry?.mayBeIncomplete == true {
                    Text("识别可能不完整，请核对原文。").font(.caption).foregroundStyle(.orange)
                }
                ScrollView {
                    Text(displayedText)
                        .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: textHeight)
                    .background(SpokenTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SpokenTheme.border))
                    .accessibilityIdentifier("recovery-text")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("场景模式").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    RecoveryScenePicker(modes: modes.modes,
                        selectedID: recovery.selectedModeID ?? modes.selected.id,
                        isEnabled: !recovery.isProcessing && !recovery.inputIsBusy && recovery.entry != nil,
                        onSelect: recovery.selectMode)
                        .frame(maxWidth: .infinity).frame(height: 32)
                }
                Text(settingDescription).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = recovery.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = recovery.copyNotice {
                    Text(notice).font(.caption).foregroundStyle(SpokenTheme.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(action: recovery.copyDisplayedText) {
                    Label(recovery.copyLabel, systemImage: "doc.on.doc").frame(height: 22)
                }.buttonStyle(.bordered).disabled(recovery.entry == nil)
                Spacer(minLength: 4)
                if recovery.isProcessing {
                    ProgressView().controlSize(.small)
                    Button(action: recovery.cancelProcessing) { Text("取消整理").frame(height: 22) }
                } else {
                    Button(action: recovery.reprocess) { Text("整理并输入").frame(height: 22) }
                        .buttonStyle(.borderedProminent).disabled(!recovery.canReprocess)
                }
            }.controlSize(.regular)
        }.padding(16).frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
            .background(SpokenTheme.background, in: RoundedRectangle(cornerRadius: 16))
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in onSizeChange(size) }
                }
            }
            .tint(SpokenTheme.accent)
            .onAppear { recovery.prepareForPresentation() }
            .onExitCommand(perform: onClose)
    }

    private var displayedText: String {
        recovery.entry == nil ? "暂无可找回的原文。" : recovery.displayedText
    }

    private var textHeight: CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let bounds = (displayedText as NSString).boundingRect(
            with: NSSize(width: Self.width - 32 - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph])
        // Short input fits its text; long input scrolls without pushing actions off screen.
        return min(200, max(64, ceil(bounds.height) + 28))
    }

    private var settingDescription: String {
        if recovery.isProcessing { return "正在按「\(recovery.processingModeName ?? "所选场景")」整理…" }
        if recovery.inputIsBusy { return "录音或正常输入进行中，完成后可重新整理。" }
        if let resultMode = recovery.resultMode {
            if resultMode.id != recovery.selectedModeID {
                return "已有结果为「\(resultMode.name)」，点击“整理并输入”应用新场景。"
            }
            return "当前结果：\(resultMode.name)"
        }
        return "整理完成后，自动填入原输入框。"
    }
}

/// Give the native popup the whole available row, including its click target.
private struct RecoveryScenePicker: NSViewRepresentable {
    let modes: [ModeDefinition]
    let selectedID: String
    let isEnabled: Bool
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13)
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("重新整理的场景")
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let choices = modes.map { ($0.id, $0.name) }
        let selectedMode = modes.first { $0.id == selectedID }
        let items = selectedMode == nil ? [(selectedID, "场景已删除，请重选")] + choices : choices
        if button.itemArray.map({ $0.title }) != items.map({ $0.1 }) ||
            button.itemArray.map({ $0.representedObject as? String }) != items.map({ Optional($0.0) }) {
            button.removeAllItems()
            for (id, name) in items {
                button.addItem(withTitle: name)
                button.lastItem?.representedObject = id
            }
        }
        button.selectItem(at: items.firstIndex { $0.0 == selectedID } ?? 0)
        button.isEnabled = isEnabled
        button.toolTip = selectedMode?.name ?? "所选场景已删除，请重新选择"
    }

    final class Coordinator: NSObject {
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }
        @objc func select(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            onSelect(id)
        }
    }
}
