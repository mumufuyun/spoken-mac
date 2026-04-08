import Foundation
import AppKit
import CoreGraphics

/// 辅助功能服务
class AccessibilityService {
    static let shared = AccessibilityService()

    private init() {}

    /// 检查辅助功能权限是否已授权
    func isAccessibilityEnabled() -> Bool {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 请求辅助功能权限
    func requestAccessibilityPermission() {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统偏好设置中的辅助功能设置页面
    func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
