import Foundation
import UserNotifications

/// 通知服务
class NotificationService {
    static let shared = NotificationService()

    private init() {
        requestPermission()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Spoken: [ERROR] Notification permission error: \(error)")
            } else {
                print("Spoken: [DEBUG] Notification permission granted: \(granted)")
            }
        }
    }

    /// 通知已输入
    func notifySuccess(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Spoken"
        content.body = "已输入: \(text.prefix(20))\(text.count > 20 ? "..." : "")"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 通知失败
    func notifyFailure(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Spoken"
        content.body = "失败: \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
