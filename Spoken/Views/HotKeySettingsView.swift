import SwiftUI

@MainActor
final class HotKeyEditor: ObservableObject {
    let service: HotKeyService
    @Published var draft: HotKeyConfiguration
    @Published var error: String?
    @Published var message = ""
    init(service: HotKeyService) { self.service = service; draft = service.configuration }
    var isDirty: Bool { draft != service.configuration }
    func capture(_ candidate: HotKeyConfiguration) { draft = candidate; error = nil; message = "尚未保存" }
    func finishCapture() { service.endCapture() }
    func discard() { finishCapture(); draft = service.configuration; error = nil; message = "" }
    func save() throws {
        finishCapture()
        do { try service.save(draft); error = nil; message = "已保存并注册" }
        catch { self.error = error.localizedDescription; message = ""; throw error }
    }
    func restoreDefault() {
        guard !service.isBusy else { error = HotKeyFailure.busy.localizedDescription; return }
        draft = .standard
        do { try save() } catch { /* Keep the draft and the old effective shortcut. */ }
    }
}

struct HotKeySettingsView: View {
    @ObservedObject var service: HotKeyService
    @StateObject private var editor: HotKeyEditor
    let navigation: SettingsNavigationGuard
    init(service: HotKeyService, navigation: SettingsNavigationGuard) {
        self.service = service; self.navigation = navigation
        _editor = StateObject(wrappedValue: HotKeyEditor(service: service))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("当前快捷键").font(.headline)
                        Spacer()
                        Text(service.displayName).font(.system(.title3, design: .monospaced))
                            .accessibilityLabel(service.accessibilityName)
                        Label(service.statusText, systemImage: service.isRegistered ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(service.warning == nil ? Color.secondary : Color.orange).font(.callout)
                    }
                    if let warning = service.warning {
                        Text(warning).foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("重新检测") { editor.finishCapture(); service.recheck() }
                        .disabled(service.isBusy || service.isCapturing)
                        .help("重新尝试注册已保存的组合，不会保存草稿")
                }.padding(18).background(SpokenTheme.surface, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("设置新的组合").font(.headline)
                    Text("点击下方录入框，按住 Command、Control 或 Option，再按一个字符键、空格或 F1–F20。可以叠加 Shift；Esc 取消录入。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HotKeyRecorder(service: service, draft: editor.draft, onCaptured: editor.capture,
                                   onError: { editor.error = $0; editor.message = "" })
                        .frame(maxWidth: 350).frame(height: 44)
                    HStack {
                        if service.isCapturing { Button("取消录入") { editor.finishCapture() } }
                        Button("恢复默认") { editor.restoreDefault() }
                            .disabled(service.isBusy || service.isCapturing)
                        Spacer()
                        Button("保存") { do { try editor.save() } catch {} }
                            .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                            .disabled(service.isBusy || service.isCapturing)
                    }
                    if service.isBusy { Text(HotKeyFailure.busy.localizedDescription).font(.callout).foregroundStyle(.orange) }
                    SettingsFeedback(error: editor.error, message: editor.message)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("如何使用").font(.headline)
                    Text("1. 回到目标应用，把光标放在输入框。\n2. 按一次 \(service.displayName) 开始录音，再按一次结束。\n3. 处理中再按 \(service.displayName) 或 Esc 取消；录音中也可按 Esc 取消。")
                        .font(.callout).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    Text("录入快捷键时 Spoken 会暂时停用自己的快捷键，完成、取消或离开后恢复。修改成功后，菜单栏和录音浮窗会同步显示新的组合。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("冲突检测范围").font(.headline).padding(.top, 6)
                    Text("Spoken 检查系统已启用快捷键、自身命令，并尝试独占注册。已注册不代表与所有软件均无冲突：其他软件的非独占注册、应用内快捷键或自行监听按键可能无法检测。独占注册也可能暂时阻止其他非独占快捷键响应。如有冲突，请选择其他组合。Spoken 不会自动换键，也不会修改其他软件设置。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24)
        }
        .onAppear {
            navigation.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard,
                               prepareNavigation: editor.finishCapture)
        }
        .onDisappear { editor.finishCapture() }
        .onChange(of: service.state) { _, state in if state != .registered { editor.message = "" } }
    }
}

/// Capture state is independent of the responder so cancellation and key-up ordering can be tested offline.
@MainActor
final class HotKeyCaptureSession {
    let service: HotKeyService
    private(set) var active = false
    private(set) var pending: HotKeyConfiguration?
    var onCaptured: (HotKeyConfiguration) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    init(service: HotKeyService) { self.service = service }
    func begin() throws { try service.beginCapture(); active = true; pending = nil }
    func finish() {
        guard active else { return }
        active = false; pending = nil; service.endCapture()
    }
    @discardableResult func consume(keyCode: UInt32, flags: NSEvent.ModifierFlags, down: Bool, isRepeat: Bool = false) -> Bool {
        guard active, service.isCapturing else { return false }
        if down {
            if keyCode == 53 { finish(); return true }
            guard !isRepeat, pending == nil else { return true }
            let candidate = HotKeyConfiguration(keyCode: keyCode, modifiers: HotKeyConfiguration.modifiers(from: flags))
            do { try candidate.validateSpokenCommands(); pending = candidate }
            catch { onError(error.localizedDescription) }
        } else if let candidate = pending, candidate.keyCode == keyCode {
            onCaptured(candidate); finish()
        }
        return true
    }
}

/// A local, focus-scoped recorder. No global key monitor or typed text is retained.
struct HotKeyRecorder: NSViewRepresentable {
    let service: HotKeyService
    var draft: HotKeyConfiguration
    var onCaptured: (HotKeyConfiguration) -> Void
    var onError: (String) -> Void
    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton(service: service)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.onCaptured = onCaptured; button.onError = onError
        button.draft = draft
        button.isEnabled = !service.isBusy
        if !service.isCapturing { button.finish() }
        button.refreshTitle()
    }
    static func dismantleNSView(_ button: HotKeyRecorderButton, coordinator: ()) { button.tearDown() }
}

@MainActor
final class HotKeyRecorderButton: NSButton {
    private let service: HotKeyService
    var draft: HotKeyConfiguration = .standard
    var onCaptured: (HotKeyConfiguration) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let capture: HotKeyCaptureSession
    private var ownsCapture: Bool { capture.active }
    override var acceptsFirstResponder: Bool { true }
    init(service: HotKeyService) {
        self.service = service
        self.capture = HotKeyCaptureSession(service: service)
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        target = self; action = #selector(begin)
        setAccessibilityLabel("录入快捷键")
        setAccessibilityHelp("按回车或空格开始录入，按组合键后松开完成，按 Escape 取消。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func begin() {
        guard !ownsCapture, window?.isKeyWindow == true else { return }
        window?.makeFirstResponder(self)
        do { try capture.begin() }
        catch { onError(error.localizedDescription); return }
        capture.onCaptured = { [weak self] in self?.onCaptured($0) }
        capture.onError = { [weak self] in self?.onError($0) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.ownsCapture, self.service.isCapturing else { return event }
            guard event.window === self.window, self.window?.isKeyWindow == true else { self.finish(); return event }
            return self.consume(event) ? nil : event
        }
        refreshTitle()
    }
    /// Waiting for key-up prevents the captured shortcut from immediately starting a recording on resume.
    @discardableResult func consume(_ event: NSEvent) -> Bool {
        let consumed = capture.consume(keyCode: UInt32(event.keyCode), flags: event.modifierFlags,
                                       down: event.type == .keyDown, isRepeat: event.isARepeat)
        if !capture.active { finish() }
        refreshTitle()
        return consumed
    }
    func refreshTitle() {
        title = ownsCapture ? (capture.pending == nil ? "请按组合键 · Esc 取消" : "松开按键完成录入") : draft.displayName + "  · 点击录入"
        setAccessibilityValue(ownsCapture ? title : draft.accessibilityName)
    }
    func finish() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        capture.finish()
        refreshTitle()
    }
    override func keyDown(with event: NSEvent) {
        if consume(event) { return }
        if event.keyCode == 36 || event.keyCode == 49 { begin() } else { super.keyDown(with: event) }
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDown()
        if let window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
        }
    }
    func tearDown() {
        finish()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

struct HotKeyMenuNotice: View {
    @ObservedObject var service: HotKeyService
    var onEdit: () -> Void
    var body: some View {
        if let warning = service.warning {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(service.displayName) 不可用", systemImage: "exclamationmark.triangle").font(.callout.bold())
                Text(warning).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("修改快捷键", action: onEdit)
                    Button("重新检测") { service.recheck() }.disabled(service.isBusy)
                }.controlSize(.small)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if service.showsGuide {
            VStack(alignment: .leading, spacing: 8) {
                Text("用快捷键开始说话").font(.callout.bold())
                Text("回到输入框，按 \(service.displayName) 开始，再按一次结束。处理中再按可取消，Esc 也可取消。")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("修改快捷键", action: onEdit)
                    Spacer()
                    Button("知道了") { service.acknowledgeGuide() }
                }.controlSize(.small)
            }.padding(12).background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
