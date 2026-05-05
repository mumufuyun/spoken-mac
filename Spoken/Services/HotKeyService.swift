import Foundation
import AppKit
import Carbon

/// 全局快捷键服务
/// 使用 Carbon HIToolbox 的 RegisterEventHotKey 实现
class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onTriggered: (() -> Void)?
    var onEscape: (() -> Void)?

    struct HotKeyConfig {
        var option: Bool
        var shift: Bool
        var space: Bool
    }

    private var currentConfig = HotKeyConfig(option: true, shift: false, space: false)

    init() {}

    // MARK: - 注册所有快捷键

    func registerAll(config: HotKeyConfig? = nil) {
        if let config = config {
            currentConfig = config
        }

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
                service.onTriggered?()
            case 2: // Escape
                NSLog("Spoken: [DEBUG] Escape triggered")
                service.onEscape?()
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

        // 注册 Escape 键
        let hotKeyID2 = EventHotKeyID(signature: OSType(0x45534350), id: 2)
        let result2 = RegisterEventHotKey(0x35,
                            UInt32(0),
                            hotKeyID2,
                            GetApplicationEventTarget(),
                            0,
                            &escapeHotKeyRef)
        NSLog("Spoken: [DEBUG] Escape hotkey registered with result: %d", result2)
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
        if let escapeHotKeyRef = escapeHotKeyRef {
            UnregisterEventHotKey(escapeHotKeyRef)
            self.escapeHotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregisterAll()
    }
}
