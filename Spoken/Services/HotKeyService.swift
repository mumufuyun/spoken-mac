import Foundation
import AppKit
import Carbon

/// 全局快捷键服务
/// 使用 Carbon HIToolbox 的 RegisterEventHotKey 实现
class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // 回调：当快捷键被触发时
    var onTriggered: (() -> Void)?

    private init() {}

    // MARK: - 注册快捷键 (⌥ + V)

    func register() {
        // 事件类型：按下时触发
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        // 安装事件处理器
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            service.onTriggered?()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),
                            handler,
                            1,
                            &eventType,
                            selfPtr,
                            &eventHandler)

        // 注册快捷键：⌥ + V
        // V = 0x09, Option = controlKey (bit 10)
        let modifiers: UInt32 = UInt32(controlKey)  // ⌥ 是 Option 键
        let keyCode: UInt32 = 0x09  // V 键

        let hotKeyID = EventHotKeyID(signature: OSType(0x534D4F53), // "SMOS"
                                      id: 1) // 'S' 'M' 'O' 'S' = Spoken

        RegisterEventHotKey(keyCode,
                            modifiers,
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
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

    deinit {
        unregister()
    }
}
