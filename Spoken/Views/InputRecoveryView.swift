import SwiftUI

/// A key-capable nonactivating panel permits text selection without activating Spoken.
final class InputRecoveryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct InputRecoveryView: View {
    static let size = NSSize(width: 420, height: 420)
    @ObservedObject var recovery: InputRecoveryStore
    @ObservedObject private var modes: ModeStore
    var onClose: () -> Void

    init(recovery: InputRecoveryStore, onClose: @escaping () -> Void) {
        self.recovery = recovery
        _modes = ObservedObject(wrappedValue: recovery.modes)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spoken").font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("关闭找回页面").help("关闭 · Esc")
            }
            HStack {
                Text("上次输入").font(.callout.weight(.semibold))
                Spacer()
                if recovery.result != nil {
                    Picker("查看内容", selection: $recovery.display) {
                        ForEach(InputRecoveryStore.Display.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 158)
                }
            }.frame(height: 28)
            HStack(spacing: 12) {
                Text("场景模式").font(.callout).foregroundStyle(.secondary).fixedSize()
                Picker("重新整理的场景", selection: Binding(get: { recovery.selectedModeID ?? modes.selected.id }, set: recovery.selectMode)) {
                    if let id = recovery.selectedModeID, recovery.selectedMode == nil {
                        Text("场景已删除，请重选").tag(id)
                    }
                    ForEach(modes.modes) { Text($0.name).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).frame(minWidth: 0, maxWidth: .infinity)
                    .disabled(recovery.isProcessing || recovery.inputIsBusy || recovery.entry == nil)
                    .accessibilityLabel("重新整理的场景")
                    .help(recovery.selectedMode?.name ?? "所选场景已删除，请重新选择")
            }
            if recovery.entry?.mayBeIncomplete == true {
                Text("识别可能不完整，请核对原文。").font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                Text(recovery.entry == nil ? "暂无可找回的原文。" : recovery.displayedText)
                    .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SpokenTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SpokenTheme.border))
                .accessibilityIdentifier("recovery-text")
            Text(settingDescription).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = recovery.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = recovery.copyNotice {
                Text(notice).font(.caption).foregroundStyle(SpokenTheme.accent).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(action: recovery.copyDisplayedText) { Label(recovery.copyLabel, systemImage: "doc.on.doc") }
                    .disabled(recovery.entry == nil)
                Spacer(minLength: 4)
                if recovery.isProcessing {
                    ProgressView().controlSize(.small)
                    Button("取消整理", action: recovery.cancelProcessing)
                } else {
                    Button("重新整理", action: recovery.reprocess).buttonStyle(.borderedProminent)
                        .disabled(!recovery.canReprocess)
                }
            }.controlSize(.small)
        }.padding(18).frame(width: Self.size.width, height: Self.size.height)
            .background(SpokenTheme.background, in: RoundedRectangle(cornerRadius: 16))
            .tint(SpokenTheme.accent)
            .onAppear { recovery.prepareForPresentation() }
            .onExitCommand(perform: onClose)
    }

    private var settingDescription: String {
        if recovery.isProcessing { return "正在按「\(recovery.processingModeName ?? "所选场景")」整理…" }
        if recovery.inputIsBusy { return "录音或正常输入进行中，完成后可重新整理。" }
        if let resultMode = recovery.resultMode {
            if resultMode.id != recovery.selectedModeID {
                return "已有结果为「\(resultMode.name)」，重新整理后应用新场景。"
            }
            return "当前结果：\(resultMode.name)"
        }
        return "场景仅用于这份原文，点击“重新整理”生效。"
    }
}
