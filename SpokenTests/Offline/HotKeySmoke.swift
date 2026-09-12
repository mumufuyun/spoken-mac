import SwiftUI
import Carbon

private final class HotKeySmokeDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "Spoken.HotkeySmoke.InMemory")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private final class SmokeRegistrar: HotKeyRegistering {
    let carbon = CarbonHotKeyRegistrar()
    var blocked = false
    var activeID: UInt32?
    var onEvent: ((UInt32, Bool) -> Void)? {
        get { carbon.onEvent }
        set { carbon.onEvent = newValue }
    }
    func checkSystem(_ configuration: HotKeyConfiguration) throws {
        if blocked { throw HotKeyFailure.occupied }
        try carbon.checkSystem(configuration)
    }
    func register(_ configuration: HotKeyConfiguration, id: UInt32) throws { try carbon.register(configuration, id: id); activeID = id }
    func unregister(_ id: UInt32) { carbon.unregister(id); if activeID == id { activeID = nil } }
    func isKeyDown(_ keyCode: UInt32) -> Bool { carbon.isKeyDown(keyCode) }
    func shutdown() { carbon.shutdown(); activeID = nil }
    func simulateCarbonEvent() {
        guard let activeID else { return }
        for down in [true, false] {
            var event: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(down ? kEventHotKeyPressed : kEventHotKeyReleased), GetCurrentEventTime(), 0, &event) == noErr,
                  let event else { return }
            var id = EventHotKeyID(signature: CarbonHotKeyRegistrar.signature, id: activeID)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
            SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
        }
    }
}

@MainActor
private final class HotKeySmokeController: NSObject, NSApplicationDelegate, ObservableObject {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-hotkey-smoke-" + UUID().uuidString)
    let registrar = SmokeRegistrar()
    let defaults = HotKeySmokeDefaults()
    var service: HotKeyService!
    var window: NSWindow!
    var panel: NSPanel?
    @Published var phase = "空闲"
    @Published var activations = 0
    @Published var focusResult = "尚未触发"
    @Published var blocked = false
    let navigation = SettingsNavigationGuard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let file = ConfigurationFile(url: root.appendingPathComponent("hotkey-v1.json"))
            try file.save(HotKeyConfiguration(keyCode: 40, modifiers: UInt32(cmdKey | controlKey | optionKey)))
            service = HotKeyService(file: file, registrar: registrar, defaults: defaults)
            service.onTriggered = { [weak self] in self?.trigger() }
            service.onEscape = { [weak self] in self?.cancel() }
            service.registerAll()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Spoken 快捷键隔离冒烟"
            window.minSize = NSSize(width: 820, height: 620)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HotKeySmokeView(controller: self))
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch { print("FAIL: \(error.localizedDescription)"); NSApp.terminate(nil) }
    }
    func trigger() {
        activations += 1
        if phase == "空闲" {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            phase = "模拟录音"; service.setBusy(true); service.startEscapeMonitoring()
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar; panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: Text("模拟录音 · 再按完成 · Esc 取消").padding(20))
            if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 50)) }
            self.panel = panel; panel.orderFront(nil)
            if let frontmost, let after = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                focusResult = frontmost == after ? "浮窗保留前台应用焦点" : "焦点异常"
            } else { focusResult = "无法读取前台应用，焦点待人工验证" }
        } else if phase == "模拟录音" { phase = "模拟处理" }
        else { cancel() }
    }
    func cancel() {
        phase = "空闲"; service.setBusy(false); service.stopEscapeMonitoring(); panel?.orderOut(nil); panel = nil
    }
    func simulateConflict() {
        registrar.blocked.toggle(); blocked = registrar.blocked; service.handleWake()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        navigation.allowNavigation() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        service?.unregisterAll(); try? FileManager.default.removeItem(at: root)
    }
}

private struct HotKeySmokeView: View {
    @ObservedObject var controller: HotKeySmokeController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("隔离冒烟 · 不录音，不调用模型").font(.headline)
                Spacer()
                Button(controller.blocked ? "解除模拟占用" : "模拟唤醒占用", action: controller.simulateConflict)
                    .disabled(controller.service.isBusy || controller.service.isCapturing)
                Button("退出测试") { NSApp.terminate(nil) }
            }.padding(16)
            HStack {
                Text("触发次数：\(controller.activations) · \(controller.phase) · \(controller.focusResult)")
                Spacer()
                Button("模拟 Carbon 按下 / 松开", action: controller.registrar.simulateCarbonEvent)
                Button("取消模拟输入", action: controller.cancel)
            }.font(.callout).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            HotKeySettingsView(service: controller.service, navigation: controller.navigation)
            SettingsWindowBinding(navigation: controller.navigation).frame(height: 0)
        }.background(SpokenTheme.background).tint(SpokenTheme.accent)
    }
}

@main
private struct HotKeySmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = HotKeySmokeController()
        app.delegate = delegate
        app.run()
    }
}
