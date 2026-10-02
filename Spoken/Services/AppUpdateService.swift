import AppKit
import Combine
#if !SPOKEN_OFFLINE_TESTS
import Sparkle
#endif

/// Owns update UI state. Sparkle owns scheduling, preferences, validation and installation.
@MainActor
final class AppUpdateService: NSObject, ObservableObject {
    static let shared = AppUpdateService(isBusy: { StateManager.shared.isBusy() })

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isWaitingForIdle = false
    @Published private(set) var isInstalling = false

    private let isBusy: () -> Bool
    private var pendingInstallation: (() -> Void)?
    private var started = false
    private var observations = Set<AnyCancellable>()
    #if !SPOKEN_OFFLINE_TESTS
    private var controller: SPUStandardUpdaterController?
    #endif

    init(isBusy: @escaping () -> Bool = { false }) {
        self.isBusy = isBusy
        super.init()
    }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "开发版")（\(info["CFBundleVersion"] as? String ?? "—")）"
    }

    func start() {
        guard !started else { return }
        #if !SPOKEN_OFFLINE_TESTS
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        do {
            try updater.start()
            started = true
            updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &observations)
            updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }.store(in: &observations)
            updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.lastCheckDate = $0 }.store(in: &observations)
            // Only force a check at startup, and always respect the user's saved preference.
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch {
            statusMessage = "更新服务未能启动：\(error.localizedDescription)"
        }
        #endif
    }

    func checkForUpdates() {
        guard !isBusy(), !isInstalling, !isWaitingForIdle else { return }
        #if !SPOKEN_OFFLINE_TESTS
        guard let controller, controller.updater.canCheckForUpdates else { return }
        statusMessage = nil
        NotificationCenter.default.post(name: .spokenWillCheckForUpdates, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if !SPOKEN_OFFLINE_TESTS
        guard let updater = controller?.updater, started else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        #endif
    }

    /// The install callback must run exactly once, only after the current speech task finishes.
    func postponeInstallationIfBusy(_ installation: @escaping () -> Void) -> Bool {
        guard isBusy() else {
            isInstalling = true
            return false
        }
        pendingInstallation = installation
        isWaitingForIdle = true
        statusMessage = "更新已就绪，将在当前录音或文字处理完成后安装。"
        return true
    }

    func activityDidChange() {
        guard !isBusy(), let installation = pendingInstallation else { return }
        pendingInstallation = nil
        isWaitingForIdle = false
        isInstalling = true
        installation()
    }

    func finishUpdateSession() {
        availableVersion = nil
        pendingInstallation = nil
        isWaitingForIdle = false
        isInstalling = false
        statusMessage = nil
    }
}

extension Notification.Name {
    static let spokenWillCheckForUpdates = Notification.Name("SpokenWillCheckForUpdates")
}

#if !SPOKEN_OFFLINE_TESTS
extension AppUpdateService: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // While busy, the menu-bar indicator is enough; clicking it opens Sparkle's standard UI.
        !isBusy()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        statusMessage = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Installation state is cleared by didFinishUpdateCycle, not by closing Sparkle's UI.
        availableVersion = nil
    }

    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfBusy(installHandler)
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishUpdateSession()
        if let error = error as NSError?, error.code != Int(SUError.noUpdateError.rawValue), error.code != Int(SUError.installationCanceledError.rawValue) {
            statusMessage = "更新检查或下载未完成，请稍后重试。\(error.localizedDescription)"
        }
    }
}
#endif
