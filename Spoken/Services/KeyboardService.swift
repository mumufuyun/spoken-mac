import Foundation
import AppKit

/// 键盘输入服务
class KeyboardService {
    static let shared = KeyboardService()

    private let engine = TextInjectionEngine()

    private init() {}

    func typeText(_ text: String) {
        print("Spoken: [DEBUG] KeyboardService.typeText: \(text)")

        // 先用 CGEvent 方式
        let outcome = engine.inject(text)
        print("Spoken: [DEBUG] CGEvent outcome: \(outcome)")

        // 如果剪贴板方式说 inserted 但实际上可能没进输入框，
        // 尝试用 Accessibility API 直接设值作为补充
        if outcome == .inserted {
            let axSuccess = engine.injectViaAccessibility(text)
            print("Spoken: [DEBUG] AX fallback: \(axSuccess)")
        }

        // 延迟恢复剪贴板
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.engine.finishClipboardRestore()
        }
    }
}
