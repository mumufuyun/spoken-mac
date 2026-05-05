import Foundation
import AppKit

/// 键盘输入服务
class KeyboardService {
    static let shared = KeyboardService()

    private let engine = TextInjectionEngine()

    private init() {}

    func typeText(_ text: String) -> Bool {
        print("Spoken: [DEBUG] KeyboardService.typeText: length=\(text.count)")
        
        let outcome = engine.inject(text)
        let success = (outcome == .inserted)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.engine.finishClipboardRestore()
        }
        
        print("Spoken: [DEBUG] KeyboardService.typeText result: \(success)")
        return success
    }
    
    /// 备用注入方式：通过粘贴板 + 模拟 Cmd+V
    func typeTextViaPaste(_ text: String) -> Bool {
        print("Spoken: [DEBUG] KeyboardService.typeTextViaPaste: length=\(text.count)")
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Cmd+V 按下
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand
        
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)
        
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        cmdUp?.post(tap: .cghidEventTap)
        
        return true
    }
}
