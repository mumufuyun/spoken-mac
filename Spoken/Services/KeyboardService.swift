import Foundation
import AppKit

/// 键盘输入服务
@MainActor
class KeyboardService {
    static let shared = KeyboardService()

    private let engine = TextInjectionEngine()

    private init() {}

    func typeText(_ text: String) -> InjectionOutcome {
        print("Spoken: [DEBUG] KeyboardService.typeText: length=\(text.count)")
        
        let outcome = engine.inject(text)
        
        if let restoreID = engine.pendingRestoreID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.engine.finishClipboardRestore(expectedID: restoreID)
            }
        }
        
        print("Spoken: [DEBUG] KeyboardService.typeText result: \(outcome)")
        return outcome
    }
    
    /// 备用注入方式：通过粘贴板 + 模拟 Cmd+V
    func typeTextViaPaste(_ text: String) -> Bool {
        typeText(text) == .inserted
    }
}
