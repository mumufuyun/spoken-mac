import Foundation
import AppKit
import Carbon
import Combine

/// Physical key codes are persisted; the label is resolved using the current keyboard layout.
struct HotKeyConfiguration: Codable, Equatable, Hashable {
    var version = 1
    var keyCode: UInt32
    var modifiers: UInt32
    static let standard = HotKeyConfiguration(keyCode: 49, modifiers: UInt32(optionKey))
    static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] {
            if flags.contains(flag) { result |= UInt32(value) }
        }
        return result
    }

    func validate() throws {
        guard version == 1 else { throw HotKeyFailure.invalid("快捷键配置版本不受支持，请重新设置。") }
        guard modifiers & ~Self.modifierMask == 0,
              modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            throw HotKeyFailure.invalid("请至少按住 Command、Control 或 Option，再按一个字符键、空格或功能键。")
        }
        guard Self.characterCodes.contains(keyCode) || Self.functionNames[keyCode] != nil || keyCode == 49 else {
            throw HotKeyFailure.invalid(keyCode == 53 ? "Esc 用于取消，不能设为启动快捷键。" : "请选择字符键、空格或 F1–F20，不支持单独修饰键或 Fn。")
        }
    }

    func validateSpokenCommands() throws {
        try validate()
        // Also covers commands in settings even when that window is currently closed.
        let reserved: Set<String> = ["S", "Q", "W", "H", "M", ",", "A", "C", "V", "X", "Z"]
        if (modifiers == UInt32(cmdKey) && reserved.contains(keyName)) ||
            (modifiers == UInt32(cmdKey | shiftKey) && ["Z", "H"].contains(keyName)) ||
            (modifiers == UInt32(cmdKey | optionKey) && ["H", "M"].contains(keyName)) {
            throw HotKeyFailure.invalid("该组合用于 Spoken 的保存、窗口或文本编辑命令，请换一个组合。")
        }
    }

    var displayName: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + " " + keyName
    }
    var accessibilityName: String {
        ([(controlKey, "Control 控制键"), (optionKey, "Option 选项键"), (shiftKey, "Shift 换挡键"), (cmdKey, "Command 命令键")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1) + [keyCode == 49 ? "空格键" : "\(keyName) 键"]).joined(separator: " 加 ")
    }
    var keyName: String {
        if keyCode == 49 { return "空格" }
        if let name = Self.functionNames[keyCode] { return name }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        for layout in [source, fallback] {
            guard let pointer = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let keyboard = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(keyboard, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey, buffer.count, &length, &buffer)
            if status == noErr && length > 0 {
                let result = String(utf16CodeUnits: buffer, count: length).uppercased()
                if result.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return result }
            }
        }
        return "键码 \(keyCode)"
    }
    private static let characterCodes: Set<UInt32> = Set(Array(UInt32(0)...UInt32(35)) + Array(UInt32(37)...UInt32(47)) + [50, 65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95, 102])
    private static let functionNames: [UInt32: String] = [122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
}

enum HotKeyFailure: LocalizedError, Equatable {
    case invalid(String)
    case occupied
    case system(String, Int32)
    case busy
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .occupied: return "该组合已被系统或其他应用占用，请修改快捷键，或关闭占用软件后重新检测。"
        case .system(let stage, let code): return "快捷键\(stage)失败（错误码 \(code)），请重新检测或修改快捷键。"
        case .busy: return "录音或处理期间不能修改快捷键，请先完成或取消本次输入。"
        }
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    var onEvent: ((UInt32, Bool) -> Void)? { get set }
    func checkSystem(_ configuration: HotKeyConfiguration) throws
    func register(_ configuration: HotKeyConfiguration, id: UInt32) throws
    func unregister(_ id: UInt32)
    func isKeyDown(_ keyCode: UInt32) -> Bool
    func shutdown()
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    static let signature: UInt32 = 0x53504B4E

    func checkSystem(_ configuration: HotKeyConfiguration) throws {
        var keys: Unmanaged<CFArray>?
        let result = CopySymbolicHotKeys(&keys)
        guard result == noErr, let keys else { throw HotKeyFailure.system("系统检查", result) }
        let entries = keys.takeRetainedValue() as NSArray
        for case let entry as NSDictionary in entries {
            if (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
               (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == configuration.keyCode,
               let modifiers = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value,
               modifiers & HotKeyConfiguration.modifierMask == configuration.modifiers {
                throw HotKeyFailure.occupied
            }
        }
    }

    func register(_ configuration: HotKeyConfiguration, id: UInt32) throws {
        #if SPOKEN_OFFLINE_TESTS
        preconditionFailure("Offline tests must inject a fake hotkey registrar")
        #else
        try installHandler()
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(configuration.keyCode, configuration.modifiers,
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        NSLog("Spoken: hotkey register key=%u modifiers=%u code=%d", configuration.keyCode, configuration.modifiers, result)
        guard result == noErr, let reference else {
            if let reference { UnregisterEventHotKey(reference) }
            if result == eventHotKeyExistsErr { throw HotKeyFailure.occupied }
            throw HotKeyFailure.system("注册", result)
        }
        registrations[id] = reference
        #endif
    }

    private func installHandler() throws {
        guard handler == nil else { return }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CarbonHotKeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers to the application event target on the main thread. Do not queue stale activations.
            registrar.onEvent?(id.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, events.count, &events,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyFailure.system("监听", status) }
    }

    func unregister(_ id: UInt32) {
        guard let reference = registrations.removeValue(forKey: id) else { return }
        let status = UnregisterEventHotKey(reference)
        if status != noErr { NSLog("Spoken: hotkey unregister id=%u code=%d", id, status) }
    }
    func isKeyDown(_ keyCode: UInt32) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
    func shutdown() {
        for id in Array(registrations.keys) { unregister(id) }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class HotKeyService: ObservableObject {
    static let shared = HotKeyService(file: .local("hotkey-v1"), registrar: CarbonHotKeyRegistrar(), defaults: .standard, observesSystem: true)
    enum RegistrationState: Equatable {
        case unregistered, registered, paused, unavailable(String)
    }
    @Published private(set) var configuration: HotKeyConfiguration = .standard
    @Published private(set) var state: RegistrationState = .unregistered
    @Published private(set) var isCapturing = false
    @Published private(set) var isBusy = false
    @Published private(set) var guideAcknowledged: Bool
    @Published private(set) var layoutRevision = 0
    var onTriggered: (() -> Void)?
    var onEscape: (() -> Void)?
    var onUnavailable: (() -> Void)?
    private let file: ConfigurationFile
    private let registrar: HotKeyRegistering
    private let defaults: UserDefaults
    private let observesSystem: Bool
    private var loadFailure: String?
    private var activeID: UInt32?
    private var nextID: UInt32 = 0
    private var pressed = false
    private var started = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var layoutObserver: NSObjectProtocol?
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?
    static let guideKey = "hotkeyGuideAcknowledged.v1"

    init(file: ConfigurationFile, registrar: HotKeyRegistering, defaults: UserDefaults, observesSystem: Bool = false) {
        self.file = file; self.registrar = registrar; self.defaults = defaults; self.observesSystem = observesSystem
        guideAcknowledged = defaults.bool(forKey: Self.guideKey)
        do {
            if let saved = try file.read(HotKeyConfiguration.self) {
                try saved.validate()
                configuration = saved
            }
        } catch { loadFailure = "无法读取快捷键配置，请重新设置。\(error.localizedDescription)" }
        registrar.onEvent = { [weak self] id, down in self?.receive(id: id, down: down) }
    }

    var displayName: String { configuration.displayName }
    var accessibilityName: String { configuration.accessibilityName }
    var isRegistered: Bool { state == .registered }
    var warning: String? { if case .unavailable(let message) = state { return message }; return nil }
    var showsGuide: Bool { !guideAcknowledged && isRegistered }
    var statusText: String {
        switch state {
        case .registered: return "已注册"
        case .paused: return "录入期间暂时停用"
        case .unregistered: return "尚未注册"
        case .unavailable: return "不可用"
        }
    }
    func acknowledgeGuide() { defaults.set(true, forKey: Self.guideKey); guideAcknowledged = true }

    func registerAll() {
        guard !started else { return }
        started = true
        if observesSystem { installObservers() }
        restoreRegistration()
    }

    /// Register and persist the candidate before releasing the working registration.
    func save(_ candidate: HotKeyConfiguration) throws {
        guard !isBusy else { throw HotKeyFailure.busy }
        guard !isCapturing else { throw HotKeyFailure.invalid("请先完成或取消快捷键录入。") }
        try candidate.validateSpokenCommands()
        try registrar.checkSystem(candidate)
        if candidate == configuration, activeID != nil, loadFailure == nil {
            try file.save(candidate)
            return
        }
        let candidateID = allocateID()
        try registrar.register(candidate, id: candidateID)
        do { try file.save(candidate) }
        catch { registrar.unregister(candidateID); throw error }
        let previousID = activeID
        configuration = candidate
        loadFailure = nil
        activeID = candidateID
        pressed = registrar.isKeyDown(candidate.keyCode)
        state = .registered
        if let previousID { registrar.unregister(previousID) }
    }

    func beginCapture() throws {
        guard !isBusy else { throw HotKeyFailure.busy }
        guard !isCapturing else { return }
        isCapturing = true
        releaseActive()
        state = .paused
    }
    func endCapture() {
        guard isCapturing else { return }
        isCapturing = false
        restoreRegistration()
    }
    func setBusy(_ busy: Bool) {
        if busy { endCapture() }
        isBusy = busy
    }
    func recheck() {
        guard !isCapturing else { return }
        releaseActive()
        restoreRegistration()
    }
    func handleWake() { if started { recheck() } }

    private func restoreRegistration() {
        guard activeID == nil, !isCapturing else { return }
        do {
            if let loadFailure { throw HotKeyFailure.invalid(loadFailure) }
            try configuration.validateSpokenCommands()
            try registrar.checkSystem(configuration)
            let id = allocateID()
            try registrar.register(configuration, id: id)
            activeID = id
            pressed = registrar.isKeyDown(configuration.keyCode)
            state = .registered
        } catch {
            let wasUnavailable = warning != nil
            state = .unavailable(error.localizedDescription)
            if !wasUnavailable { onUnavailable?() }
        }
    }
    private func allocateID() -> UInt32 { nextID += 1; return nextID }
    private func releaseActive() {
        if let activeID { registrar.unregister(activeID) }
        activeID = nil; pressed = false
    }
    private func receive(id: UInt32, down: Bool) {
        guard id == activeID, isRegistered, !isCapturing else { return }
        if !down { pressed = false; return }
        guard !pressed else { return }
        pressed = true
        onTriggered?()
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            })
        }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutRevision += 1 }
            }
    }
    func startEscapeMonitoring() {
        stopEscapeMonitoring()
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, !event.isARepeat else { return }
            MainActor.assumeIsolated { self?.onEscape?() }
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            if !event.isARepeat { self?.onEscape?() }
            return nil
        }
    }
    func stopEscapeMonitoring() {
        if let escapeGlobalMonitor { NSEvent.removeMonitor(escapeGlobalMonitor); self.escapeGlobalMonitor = nil }
        if let escapeLocalMonitor { NSEvent.removeMonitor(escapeLocalMonitor); self.escapeLocalMonitor = nil }
    }
    func unregisterAll() {
        stopEscapeMonitoring()
        releaseActive()
        registrar.shutdown()
        for token in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        wakeObservers.removeAll()
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver); self.layoutObserver = nil }
        isCapturing = false; state = .unregistered; started = false
    }
}
