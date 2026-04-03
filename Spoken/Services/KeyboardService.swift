import Foundation
import AppKit

/// 键盘输入服务：模拟键盘事件将文本输入到当前焦点窗口
class KeyboardService {
    static let shared = KeyboardService()

    private init() {}

    /// 将文本逐字输入到当前焦点窗口
    /// - Parameter text: 要输入的文本
    func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        for scalar in text.unicodeScalars {
            let char = Character(scalar)
            let (keyCode, needsShift) = charToKeyCodeAndShift(char)

            if let keyCode = keyCode {
                // 普通字符：keyDown → keyUp
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

                if needsShift {
                    keyDown?.flags = .maskShift
                    keyUp?.flags = .maskShift
                } else {
                    keyDown?.flags = []
                    keyUp?.flags = []
                }

                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            } else {
                // 非 ASCII 字符（如中文）：通过 Unicode 输入
                var unicode = UniChar(scalar.value)
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                keyDown?.flags = .maskUnicode
                keyDown?.unicodeString[0] = unicode
                keyDown?.unicodeStringLength = 1
                keyDown?.post(tap: .cghidEventTap)

                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                keyUp?.flags = .maskUnicode
                keyUp?.unicodeString[0] = unicode
                keyUp?.unicodeStringLength = 1
                keyUp?.post(tap: .cghidEventTap)
            }

            // 字符间小延迟，避免过快导致丢字
            usleep(5000) // 5ms
        }
    }

    /// 将字符映射为 Mac 虚拟键码 + 是否需要 Shift
    /// 返回 (keyCode, needsShift)。keyCode 为 nil 时用 Unicode 方式输入
    private func charToKeyCodeAndShift(_ char: Character) -> (CGKeyCode?, Bool) {
        // 映射表：(keyCode, 需要Shift)
        let map: [(Character, CGKeyCode, Bool)] = [
            // 字母（统一用小写，Shift 由调用方处理）
            ("a", 0x00, false), ("b", 0x0B, false), ("c", 0x08, false), ("d", 0x02, false),
            ("e", 0x0E, false), ("f", 0x03, false), ("g", 0x05, false), ("h", 0x04, false),
            ("i", 0x22, false), ("j", 0x26, false), ("k", 0x28, false), ("l", 0x25, false),
            ("m", 0x2E, false), ("n", 0x2D, false), ("o", 0x1F, false), ("p", 0x23, false),
            ("q", 0x0C, false), ("r", 0x0F, false), ("s", 0x01, false), ("t", 0x11, false),
            ("u", 0x20, false), ("v", 0x09, false), ("w", 0x0D, false), ("x", 0x07, false),
            ("y", 0x10, false), ("z", 0x06, false),
            // 数字
            ("1", 0x12, false), ("2", 0x13, false), ("3", 0x14, false), ("4", 0x15, false),
            ("5", 0x17, false), ("6", 0x16, false), ("7", 0x1A, false), ("8", 0x1C, false),
            ("9", 0x19, false), ("0", 0x1D, false),
            // 空格 / 回车 / Tab
            (" ", 0x31, false), ("\n", 0x24, false), ("\t", 0x30, false),
            // 符号（需要 Shift）
            ("!", 0x12, true), ("@", 0x13, true), ("#", 0x14, true),
            ("$", 0x15, true), ("%", 0x17, true), ("^", 0x16, true),
            ("&", 0x1A, true), ("*", 0x1C, true), ("(", 0x19, true),
            (")", 0x1D, true), ("_", 0x1B, true), ("+", 0x18, true),
            ("{", 0x21, true), ("}", 0x1E, true), ("|", 0x2A, true),
            (":", 0x29, true), ("\"", 0x27, true), ("<", 0x2B, true),
            (">", 0x2F, true), ("?", 0x2C, true), ("~", 0x32, true),
            // 符号（不需要 Shift）
            ("-", 0x1B, false), ("=", 0x18, false), ("[", 0x21, false),
            ("]", 0x1E, false), ("\\", 0x2A, false), (";", 0x29, false),
            ("'", 0x27, false), (",", 0x2B, false), (".", 0x2F, false),
            ("/", 0x2C, false), ("`", 0x32, false),
        ]

        let lower = String(char).lowercased().first ?? char
        if let entry = map.first(where: { $0.0 == lower }) {
            // 原始字符是大写或符号，需要 Shift
            let needsShift = char != lower
            return (entry.1, needsShift || entry.2)
        }

        // 中文字符或其他非 ASCII 字符
        if char.unicodeScalars.first.map({ $0.value > 127 }) == true {
            return (nil, false)
        }

        return (nil, false)
    }
}
