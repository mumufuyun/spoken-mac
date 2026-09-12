import AppKit
import ApplicationServices
import Combine

enum TextInputPermission: Equatable {
    case notAuthorized, eventPostingDenied, ready

    var statusText: String {
        switch self {
        case .notAuthorized: return "辅助功能未授权"
        case .eventPostingDenied: return "自动输入权限尚未生效"
        case .ready: return "辅助功能已授权"
        }
    }
}

/// Permission is always read from macOS, never inferred from a guide acknowledgment.
@MainActor
final class AccessibilityPermissionService: ObservableObject {
    static let shared: AccessibilityPermissionService = {
        #if SPOKEN_OFFLINE_TESTS
        preconditionFailure("Offline tests must inject accessibility dependencies")
        #else
        return AccessibilityPermissionService(defaults: .standard, readPermission: {
            guard AXIsProcessTrusted() else { return .notAuthorized }
            return CGPreflightPostEventAccess() ? .ready : .eventPostingDenied
        }, openSettings: {
            // Only invoked by the user's authorization button. This registers the current app
            // with TCC; it does not grant access or change another application's permissions.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }, revealApplication: {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        })
        #endif
    }()

    static let guideKey = "accessibilityGuidePresented.v1"
    @Published private(set) var state: TextInputPermission
    @Published private(set) var feedback: String?
    private let defaults: UserDefaults
    private let readPermission: () -> TextInputPermission
    private let settingsAction: () -> Bool
    private let revealAction: () -> Void
    private let now: () -> Date
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var visibleGuides = 0
    private var watchUntil = Date.distantPast

    init(defaults: UserDefaults, readPermission: @escaping () -> TextInputPermission,
         openSettings: @escaping () -> Bool, revealApplication: @escaping () -> Void = {},
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.readPermission = readPermission
        settingsAction = openSettings; revealAction = revealApplication; self.now = now
        state = readPermission()
    }

    var canAutoPaste: Bool { state == .ready }
    var needsAttention: Bool { !canAutoPaste }
    var needsInitialGuide: Bool { needsAttention && !defaults.bool(forKey: Self.guideKey) }
    var shouldPoll: Bool { visibleGuides > 0 || now() < watchUntil }

    @discardableResult func refresh() -> Bool {
        let current = readPermission()
        if state != current { state = current; feedback = nil }
        return canAutoPaste
    }

    func recheck() {
        feedback = refresh()
            ? "权限已生效。回到目标输入框即可继续使用。"
            : "尚未检测到有效授权。请开启当前 Spoken 的开关，再点击重新检测。"
    }

    func markGuidePresented() { defaults.set(true, forKey: Self.guideKey) }

    func openSettings() {
        watchUntil = now().addingTimeInterval(120)
        let opened = settingsAction()
        refresh()
        feedback = opened ? nil : "未能打开系统设置。请手动前往：系统设置 → 隐私与安全性 → 辅助功能。"
    }

    func revealApplication() { revealAction() }
    func guideAppeared() { visibleGuides += 1; refresh() }
    func guideDisappeared() { visibleGuides = max(0, visibleGuides - 1) }

    func startMonitoring() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shouldPoll else { return }
                self.refresh()
            }
        }
        refresh()
    }

    func stopMonitoring() {
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
