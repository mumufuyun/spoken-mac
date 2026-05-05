import Foundation
import AppKit
import Carbon

/// 全局快捷键服务
/// 使用 Carbon HIToolbox 的 RegisterEventHotKey 实现
class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var escapeEventHandler: EventHandlerRef?

    var onTriggered: (() -> Void)?
    var onEscape: (() -> Void)?

    struct HotKeyConfig {
        var option: Bool
        var shift: Bool
        var space: Bool
    }

    private var currentConfig = HotKeyConfig(option: true, shift: false, space: false)

    init() {}

    // MARK: - 注册快捷键

    func register(config: HotKeyConfig? = nil) {
        if let config = config {
            currentConfig = config
        }

        // 事件类型：按下时触发
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        // 安装事件处理器
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            NSLog("Spoken: [DEBUG] HotKey triggered")
            
            service.onTriggered?()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerInstalled = InstallEventHandler(GetApplicationEventTarget(),
                            handler,
                            1,
                            &eventType,
                            selfPtr,
                            &eventHandler)
        NSLog("Spoken: [DEBUG] Event handler installed: %d", handlerInstalled)

        // 注册快捷键：⌥ + 空格（默认）
        let modifiers: UInt32 = computeModifiers()
        let keyCode: UInt32 = currentConfig.space ? 0x31 : 0x31  // 空格

        let hotKeyID = EventHotKeyID(signature: OSType(0x534D4F53), // "SMOS"
                                      id: 1)

        let result = RegisterEventHotKey(keyCode,
                            modifiers,
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
        NSLog("Spoken: [DEBUG] HotKey registered with result: %d", result)
    }

    private func computeModifiers() -> UInt32 {
        var modifiers: UInt32 = 0
        if currentConfig.option { modifiers |= UInt32(optionKey) }
        if currentConfig.shift { modifiers |= UInt32(shiftKey) }
        if currentConfig.space { /* space is handled by keyCode */ }
        return modifiers
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    func unregisterAll() {
        unregister()
        unregisterEscape()
    }

    func registerOptionSpaceHotKey() {
        register()
    }

    // MARK: - Escape 键

    func registerEscape() {
        // 事件类型：按下时触发
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        // 安装事件处理器
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            NSLog("Spoken: [DEBUG] Escape triggered")
            service.onEscape?()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerInstalled = InstallEventHandler(GetApplicationEventTarget(),
                            handler,
                            1,
                            &eventType,
                            selfPtr,
                            &escapeEventHandler)
        NSLog("Spoken: [DEBUG] Escape event handler installed: %d", handlerInstalled)

        // 注册 Escape 键 (keyCode: 0x35)
        let hotKeyID = EventHotKeyID(signature: OSType(0x45534350), // "ESCP"
                                      id: 2)

        let result = RegisterEventHotKey(0x35,
                            UInt32(0),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &escapeHotKeyRef)
        NSLog("Spoken: [DEBUG] Escape hotkey registered with result: %d", result)
    }

    func unregisterEscape() {
        if let hotKeyRef = escapeHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.escapeHotKeyRef = nil
        }
        if let eventHandler = escapeEventHandler {
            RemoveEventHandler(eventHandler)
            self.escapeEventHandler = nil
        }
    }

    deinit {
        unregister()
        unregisterEscape()
    }
}
