import Foundation
import AppKit
import Carbon

/// 全局快捷键服务
/// 使用 Carbon HIToolbox 的 RegisterEventHotKey 实现
@MainActor
class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    var onTriggered: (() -> Void)?
    var onEscape: (() -> Void)?

    struct HotKeyConfig {
        var option: Bool
        var shift: Bool
        var space: Bool
    }

    private var currentConfig = HotKeyConfig(option: true, shift: false, space: false)

    /// 系统睡眠/唤醒观察者令牌，用于在唤醒后重新注册快捷键
    private var wakeObserverTokens: [NSObjectProtocol] = []

    init() {}

    // MARK: - 注册所有快捷键

    func registerAll(config: HotKeyConfig? = nil) {
        if let config = config {
            currentConfig = config
        }

        // 先清理旧注册，避免重复安装事件处理器或热键引用泄漏
        unregisterAll()

        // 只安装一个统一的事件处理器
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }

            // 获取 hotKeyID 以区分不同的快捷键
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()

            switch hotKeyID.id {
            case 1: // ⌥+空格
                NSLog("Spoken: [DEBUG] HotKey triggered")
                DispatchQueue.main.async { service.onTriggered?() }
            default:
                return OSStatus(eventNotHandledErr)
            }

            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerInstalled = InstallEventHandler(GetApplicationEventTarget(),
                            handler,
                            1,
                            &eventType,
                            selfPtr,
                            &eventHandler)
        NSLog("Spoken: [DEBUG] Unified event handler installed: %d", handlerInstalled)

        // 注册 ⌥+空格
        let modifiers: UInt32 = computeModifiers()
        let keyCode: UInt32 = currentConfig.space ? 0x31 : 0x31

        let hotKeyID1 = EventHotKeyID(signature: OSType(0x534D4F53), id: 1)
        let result1 = RegisterEventHotKey(keyCode,
                            modifiers,
                            hotKeyID1,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
        NSLog("Spoken: [DEBUG] HotKey registered with result: %d", result1)

        // 注册系统唤醒观察者，在睡眠/屏幕保护后自动恢复热键
        registerWakeObservers()
    }

    /// Escape 只在录音面板可见时监听。全局 monitor 不会吞掉其他应用的按键，
    /// 本地 monitor 则在 Spoken 自身获得事件时阻止继续传递。
    func startEscapeMonitoring() {
        stopEscapeMonitoring()
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.onEscape?() }
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.onEscape?()
            return nil
        }
    }

    func stopEscapeMonitoring() {
        if let escapeGlobalMonitor {
            NSEvent.removeMonitor(escapeGlobalMonitor)
            self.escapeGlobalMonitor = nil
        }
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
            self.escapeLocalMonitor = nil
        }
    }

    /// 监听系统唤醒事件，唤醒后重新注册全局热键。
    /// Carbon RegisterEventHotKey 在系统睡眠或长时间闲置后可能会失效，
    /// 重新注册是避免必须重启应用才能恢复快捷键的最小改动。
    private func registerWakeObservers() {
        // 先移除旧的观察者，防止重复注册
        for token in wakeObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        wakeObserverTokens.removeAll()

        let center = NSWorkspace.shared.notificationCenter
        let wakeNotifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]

        for name in wakeNotifications {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let notificationName = notification.name.rawValue
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    NSLog("Spoken: [DEBUG] %@ received, re-registering hotkeys", notificationName)
                    self.unregisterAll()
                    self.registerAll()
                }
            }
            wakeObserverTokens.append(token)
        }
    }

    private func computeModifiers() -> UInt32 {
        var modifiers: UInt32 = 0
        if currentConfig.option { modifiers |= UInt32(optionKey) }
        if currentConfig.shift { modifiers |= UInt32(shiftKey) }
        if currentConfig.space { /* space is handled by keyCode */ }
        return modifiers
    }

    func unregisterAll() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        for token in wakeObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        wakeObserverTokens.removeAll()
    }
}
