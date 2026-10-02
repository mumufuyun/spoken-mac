import AppKit
import Combine
import Sparkle

// Test-only speech state; the production update service is compiled unchanged below.
@MainActor
final class StateManager {
    static let shared = StateManager()
    var busy = true
    func isBusy() -> Bool { busy }
}

@MainActor
final class UpdateIntegrationApp: NSObject, NSApplicationDelegate {
    var updater: SPUUpdater!
    var driver: TestDriver!
    let service = AppUpdateService.shared
    var observations = Set<AnyCancellable>()

    func record(_ event: String) {
        let url = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "TestResultPath") as! String)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try! (old + event + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            record("RELAUNCHED 2")
            NSApp.terminate(nil)
            return
        }
        for selector in ["updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:"] {
            precondition(service.responds(to: NSSelectorFromString(selector)), "Missing production delegate: " + selector)
        }
        let scenario = Bundle.main.object(forInfoDictionaryKey: "TestScenario") as? String
        if scenario == "checks-disabled" || scenario == "automatic-check" {
            StateManager.shared.busy = false
            service.start()
            service.start()
            if scenario == "checks-disabled" {
                service.setAutomaticChecks(true)
                service.setAutomaticChecks(false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                precondition(self.service.canCheckForUpdates)
                if scenario == "checks-disabled" {
                    precondition(!self.service.automaticallyChecksForUpdates)
                    precondition(!UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks"))
                    self.record("AUTO_DISABLED")
                } else {
                    precondition(self.service.lastCheckDate != nil)
                    precondition(self.service.statusMessage == nil)
                    self.record("AUTO_CHECKED")
                }
                NSApp.terminate(nil)
            }
            return
        }
        service.$isWaitingForIdle.receive(on: DispatchQueue.main).sink { [weak self] waiting in
            guard let self, waiting else { return }
            self.record("POSTPONE")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                StateManager.shared.busy = false
                self.record("RESUME")
                self.service.activityDidChange()
                precondition(self.service.isInstalling)
            }
        }.store(in: &observations)
        driver = TestDriver()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: service)
        do { try updater.start() }
        catch { record("START_ERROR " + error.localizedDescription); exit(1) }
        updater.checkForUpdates()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { self.record("TIMEOUT"); NSApp.terminate(nil) }
    }
}

@main
enum UpdateIntegration {
    @MainActor static func main() {
        let delegate = UpdateIntegrationApp()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
