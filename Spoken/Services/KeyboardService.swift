import Foundation
import AppKit

/// 键盘输入服务
class KeyboardService {
    static let shared = KeyboardService()

    private let engine = TextInjectionEngine()

    private init() {}

    func typeText(_ text: String) -> Bool {
        print("Spoken: [DEBUG] KeyboardService.typeText: \(text)")

        // 直接使用剪贴板方式，完全照搬 type4me 的实现
        print("Spoken: [DEBUG] Using clipboard method")
        let outcome = engine.inject(text)
        print("Spoken: [DEBUG] Clipboard outcome: \(outcome)")
        let success = (outcome == .inserted)

        // 延迟恢复剪贴板
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.engine.finishClipboardRestore()
        }

        print("Spoken: [DEBUG] Final success: \(success)")
        return success
    }
}
