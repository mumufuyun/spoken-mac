import AppKit
import SwiftUI
import Network
import Combine

enum AppState: String, CaseIterable {
    case idle
    case starting
    case recording
    case cloudRecognizing
    case finishing
    case injecting
    case postProcessing
    case recovering
}

enum FloatingInputPanelLayout {
    static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let bottomInset: CGFloat = 200
        let edgeInset: CGFloat = 16
        let origin = NSPoint(
            x: max(visibleFrame.minX + edgeInset,
                   min(visibleFrame.midX - size.width / 2,
                       visibleFrame.maxX - size.width - edgeInset)),
            y: max(visibleFrame.minY + edgeInset,
                   min(visibleFrame.minY + bottomInset,
                       visibleFrame.maxY - size.height - edgeInset))
        )
        return NSRect(origin: origin, size: size)
    }
}

@MainActor
class StateManager: ObservableObject {
    static let shared = StateManager()

    @Published var currentState: AppState = .idle

    private init() {}

    func transition(to newState: AppState) {
        guard currentState != newState else { return }
        print("Spoken: [DEBUG] State transition: \(currentState.rawValue) -> \(newState.rawValue)")
        currentState = newState
    }

    func isIdle() -> Bool {
        return currentState == .idle
    }

    func isBusy() -> Bool {
        return currentState != .idle
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyService: HotKeyService!
    private var recordingPanel: NSPanel?
    private var recoveryPanel: InputRecoveryPanel?
    private var processingNoticePanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var hotKeyNoticePanel: NSPanel?
    private var hotKeyStateSubscription: AnyCancellable?
    private var accessibilitySubscription: AnyCancellable?
    private var updateSubscriptions = Set<AnyCancellable>()
    private var accessibilityGuidePanel: NSPanel?
    private var deliveryNoticePanel: NSPanel?
    private var accessibility: AccessibilityPermissionService { .shared }
    private var recordingViewModel = RecordingViewModel()
    private var frontmostAppBeforeHotKey: NSRunningApplication?
    private var inputTargetBeforeHotKey: RecoveryInputTarget?
    private let stateManager = StateManager.shared
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.moss.spoken.network-monitor")
    private var networkSignature: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupHotKey()
        setupAccessibilityMonitoring()
        setupUpdates()
        registerSleepWakeObservers()
        startNetworkMonitoring()
        checkPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            SpeechService.shared.prepareCloudConnection()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let navigation = settingsWindow?.delegate as? SettingsNavigationGuard, !navigation.allowNavigation() {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        InputRecoveryStore.shared.cancelProcessing()
        hotKeyService?.unregisterAll()
        accessibility.stopMonitoring()
        networkMonitor.cancel()
        CloudSpeechService.shared.disconnect()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === accessibilityGuidePanel else { return }
        window.contentView = nil
        accessibilityGuidePanel = nil
    }

    // MARK: - Status Item

    private func setupUpdates() {
        let updates = AppUpdateService.shared
        updates.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusItem()
        }.store(in: &updateSubscriptions)
        stateManager.$currentState.receive(on: DispatchQueue.main).sink { _ in
            updates.activityDidChange()
        }.store(in: &updateSubscriptions)
        NotificationCenter.default.publisher(for: .spokenWillCheckForUpdates).sink { [weak self] _ in
            self?.popover.performClose(nil)
        }.store(in: &updateSubscriptions)
        updates.start()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Spoken") {
                image.size = NSSize(width: 14, height: 14)
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🎤"
            }
            button.toolTip = "语言是最好的输入"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        let contentView = ContentView { [weak self] section in
            self?.showSettingsWindow(section: section)
        }
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: ContentView.panelHeight)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            accessibility.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Settings Window

    private func showSettingsWindow(section: SettingsSection = .modes) {
        if popover.isShown {
            popover.performClose(nil)
        }

        let window: NSWindow
        if let existingWindow = settingsWindow {
            window = existingWindow
        } else {
            let hostingController = NSHostingController(rootView: SettingsView(initialSection: section))
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Spoken 设置"
            newWindow.contentViewController = hostingController
            newWindow.minSize = NSSize(width: 820, height: 580)
            newWindow.isReleasedWhenClosed = false
            newWindow.collectionBehavior.insert(.moveToActiveSpace)
            if !newWindow.setFrameUsingName("SpokenSettingsWindow") {
                newWindow.center()
            }
            newWindow.setFrameAutosaveName("SpokenSettingsWindow")
            settingsWindow = newWindow
            window = newWindow
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Notification.Name("SpokenOpenSettingsSection"), object: section)
    }

    // MARK: - Global HotKey

    private func setupHotKey() {
        hotKeyService = HotKeyService.shared
        hotKeyService.onTriggered = { [weak self] in self?.handleHotKey() }
        hotKeyService.onEscape = { [weak self] in
            guard let self else { return }
            if self.recoveryPanel?.isVisible == true { self.closeRecoveryPanel() }
            else if self.recordingPanel?.isVisible == true { self.recordingViewModel.cancel() }
        }
        hotKeyService.onUnavailable = { [weak self] in self?.showHotKeyNotice() }
        // Read the completed state after @Published has updated. A queued initial/paused state
        // must not immediately dismiss the conflict notice created by the following failure.
        hotKeyStateSubscription = hotKeyService.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateStatusItem()
            if self.hotKeyService.warning == nil { self.hotKeyNoticePanel?.orderOut(nil); self.hotKeyNoticePanel = nil }
        }
        hotKeyService.registerAll()
    }

    /// A nonactivating notice: a conflict never moves focus away from the user's input application.
    private func showHotKeyNotice() {
        hotKeyNoticePanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HotKeyMenuNotice(service: hotKeyService, onEdit: { [weak self, weak panel] in
            self?.showSettingsWindow(section: .shortcuts)
            panel?.orderOut(nil)
        }).padding(12).frame(width: 380).background(SpokenTheme.background, in: RoundedRectangle(cornerRadius: 14)))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 400, y: screen.visibleFrame.maxY - 200))
        }
        hotKeyNoticePanel = panel
        panel.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak panel] in
            guard let panel, self?.hotKeyNoticePanel === panel else { return }
            panel.orderOut(nil); self?.hotKeyNoticePanel = nil
        }
    }

    // MARK: - Sleep / Wake

    /// 系统睡眠前主动断开云端连接，避免在休眠期间持有死连接；
    /// 唤醒后重置连接状态，确保首次录音走全新连接。
    private func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                print("Spoken: [DEBUG] System will sleep, disconnecting cloud speech")
                if self?.recordingPanel?.isVisible == true {
                    self?.recordingViewModel.cancel()
                }
                CloudSpeechService.shared.disconnect()
            }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("Spoken: [DEBUG] System did wake, resetting cloud speech connection")
            CloudSpeechService.shared.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                SpeechService.shared.prepareCloudConnection()
            }
        }
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let interfaceTypes: [NWInterface.InterfaceType] = [
                .wifi, .wiredEthernet, .cellular, .loopback, .other
            ]
            let activeInterfaces = interfaceTypes
                .filter(path.usesInterfaceType)
                .map { String(describing: $0) }
                .joined(separator: ",")
            let signature = "\(String(describing: path.status))|\(activeInterfaces)"
            DispatchQueue.main.async {
                guard let self else { return }
                let previous = self.networkSignature
                self.networkSignature = signature
                guard let previous, previous != signature else { return }
                guard self.stateManager.isIdle() else {
                    print("Spoken: [DEBUG] Network path changed while busy; preserving the active speech session")
                    return
                }
                print("Spoken: [DEBUG] Network path changed, rebuilding cloud speech warm connection")
                CloudSpeechService.shared.disconnect()
                if path.status == .satisfied {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        SpeechService.shared.prepareCloudConnection()
                    }
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleHotKey() {
        guard !AppUpdateService.shared.isInstalling, stateManager.currentState != .injecting else { return }
        if recoveryPanel != nil {
            closeRecoveryPanel()
            popover.performClose(nil)
        } else if popover.isShown {
            popover.performClose(nil)
            return
        }
        if recordingPanel?.isVisible == true {
            if recordingViewModel.isRecording {
                recordingViewModel.stopRecording()
            } else {
                recordingViewModel.cancel()
            }
            return
        }
        PipelineLatencyMetrics.shared.begin()
        SpeechService.shared.prepareCloudConnection()
        showRecordingPanel()
    }

    // MARK: - Recording Panel

    private func showRecordingPanel() {
        accessibility.refresh()
        deliveryNoticePanel?.orderOut(nil)
        deliveryNoticePanel = nil
        accessibilityGuidePanel?.close()
        accessibilityGuidePanel = nil
        processingNoticePanel?.orderOut(nil)
        processingNoticePanel = nil
        frontmostAppBeforeHotKey = NSWorkspace.shared.frontmostApplication
        print("Spoken: [DEBUG] AppDelegate frontmost app saved: \(frontmostAppBeforeHotKey?.localizedName ?? "unknown")")

        hotKeyService.setBusy(true)
        stateManager.transition(to: .starting)

        let recovery = InputRecoveryStore.shared
        inputTargetBeforeHotKey = recovery.entry == nil ? nil : RecoveryInputTarget.capture(application: frontmostAppBeforeHotKey)
        let viewModel = RecordingViewModel(retainOriginal: { text, incomplete in
            recovery.capture(text, mayBeIncomplete: incomplete)
        })
        viewModel.hasRecoverableInput = recovery.entry != nil
        viewModel.onRecover = { [weak self] in self?.showRecoveryPanel() }
        viewModel.targetApplication = frontmostAppBeforeHotKey
        let recordingView = RecordingPanelView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: recordingView)
        let panelSize = NSSize(width: RecordingPanelView.width, height: RecordingViewModel.collapsedHeight)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hostingController
        panel.hidesOnDeactivate = false
        viewModel.onPanelResize = { [weak panel] height in
            guard let panel else { return }
            var frame = panel.frame
            frame.size = NSSize(width: panelSize.width, height: height)
            if let screen = panel.screen ?? NSScreen.main {
                frame = FloatingInputPanelLayout.frame(for: frame.size, in: screen.visibleFrame)
            }
            panel.setFrame(frame, display: true)
        }

        // NSHostingController can temporarily reset the panel frame to zero before layout.
        // Position using the view's intended size, not that transient window frame.
        panel.setContentSize(panelSize)
        if let screen = NSScreen.main {
            panel.setFrame(FloatingInputPanelLayout.frame(for: panelSize, in: screen.visibleFrame), display: true)
        }

        viewModel.onCancel = { [weak self, weak panel] in
            guard let strongSelf = self else { return }
            strongSelf.hotKeyService.stopEscapeMonitoring()
            strongSelf.stateManager.transition(to: .idle)
            PipelineLatencyMetrics.shared.abandon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let panel, strongSelf.recordingPanel === panel else { return }
                strongSelf.recordingPanel?.orderOut(nil)
                strongSelf.recordingPanel = nil
                strongSelf.hotKeyService.setBusy(false)
            }
        }

        viewModel.onClose = { [weak self] in
            self?.hotKeyService.stopEscapeMonitoring()
            self?.recordingPanel?.orderOut(nil)
            self?.recordingPanel = nil
            self?.hotKeyService.setBusy(false)
        }

        viewModel.onComplete = { [weak self] text, appFromViewModel in
            guard let strongSelf = self else { return }
            let targetApp = appFromViewModel ?? strongSelf.frontmostAppBeforeHotKey
            strongSelf.performTextInjection(text: text, targetApp: targetApp)
        }
        viewModel.onRecognitionFailure = { [weak self] message in self?.showProcessingNotice(message) }

        self.recordingViewModel = viewModel
        self.recordingPanel = panel
        hotKeyService.startEscapeMonitoring()
        panel.orderFront(nil)
        PipelineLatencyMetrics.shared.mark(.panelShown)

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.recordingPanel === panel, !viewModel.isCancelled else { return }
            viewModel.startRecording()
        }
    }

    // MARK: - Input Recovery

    private func showRecoveryPanel() {
        let recovery = InputRecoveryStore.shared
        guard recordingViewModel.canRecoverInput, recovery.entry != nil,
              !AppUpdateService.shared.isInstalling else { return }
        let screen = recordingPanel?.screen ?? NSScreen.main
        let targetApp = recordingViewModel.targetApplication ?? frontmostAppBeforeHotKey
        let inputTarget = inputTargetBeforeHotKey
        // Cancel capture before showing recovery. This invalidates late ASR callbacks and
        // keeps the previous original even if this recording already produced partial speech.
        recordingViewModel.cancel()
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
        recovery.prepareForPresentation()
        let panel = InputRecoveryPanel(contentRect: NSRect(origin: .zero, size: InputRecoveryView.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: InputRecoveryView(recovery: recovery) { [weak self] in self?.closeRecoveryPanel() })
        panel.setContentSize(InputRecoveryView.size)
        if let screen {
            panel.setFrame(FloatingInputPanelLayout.frame(for: InputRecoveryView.size, in: screen.visibleFrame), display: true)
        } else {
            panel.center()
        }
        recoveryPanel = panel
        recovery.onProcessed = { [weak self, weak panel] text in
            guard let self, let panel, self.recoveryPanel === panel, panel.isVisible else { return }
            self.closeRecoveryPanel()
            self.performTextInjection(text: text, targetApp: targetApp,
                                      targetIsReady: { inputTarget?.restoreFocus() == true })
        }
        hotKeyService.setBusy(true)
        hotKeyService.startEscapeMonitoring()
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeRecoveryPanel() {
        InputRecoveryStore.shared.cancelProcessing()
        InputRecoveryStore.shared.onProcessed = nil
        recoveryPanel?.orderOut(nil)
        recoveryPanel?.contentView = nil
        recoveryPanel = nil
        hotKeyService.stopEscapeMonitoring()
        hotKeyService.setBusy(stateManager.isBusy())
    }

    // MARK: - Text Injection

    private func performTextInjection(text: String, targetApp: NSRunningApplication?,
                                      targetIsReady: @escaping () -> Bool = { true }) {
        print("Spoken: [DEBUG] performTextInjection - text length: \(text.count)")
        stateManager.transition(to: .injecting)
        PipelineLatencyMetrics.shared.mark(.injectionStarted)

        recordingPanel?.orderOut(nil)

        if let app = targetApp {
            print("Spoken: [DEBUG] Activating: \(app.localizedName ?? "unknown")")
            app.activate(options: [.activateAllWindows])
        } else {
            print("Spoken: [WARN] No target app found")
        }

        waitForTargetAndInject(
            text: text,
            targetApp: targetApp,
            targetIsReady: targetIsReady,
            deadline: ProcessInfo.processInfo.systemUptime + 0.8
        )
    }

    private func waitForTargetAndInject(
        text: String,
        targetApp: NSRunningApplication?,
        targetIsReady: @escaping () -> Bool,
        deadline: TimeInterval
    ) {
        let targetAppIsReady = targetApp.map {
            !$0.isTerminated
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier
        } ?? true
        if targetAppIsReady || ProcessInfo.processInfo.systemUptime >= deadline {
            executeInjection(text: text, targetApp: targetApp, targetIsReady: targetIsReady)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForTargetAndInject(text: text, targetApp: targetApp, targetIsReady: targetIsReady, deadline: deadline)
        }
    }

    private func executeInjection(text: String, targetApp: NSRunningApplication?, targetIsReady: () -> Bool) {
        let outcome: InjectionOutcome
        let permissionGranted = accessibility.refresh()
        if let targetApp, !targetApp.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
            outcome = KeyboardService.shared.typeText(text, targetIsReady: targetIsReady)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            outcome = pb.setString(text, forType: .string)
                ? (permissionGranted ? .copiedToClipboard : .permissionRequired) : .clipboardFailed
        }
        PipelineLatencyMetrics.shared.finish()
        cleanupAfterInjection(showFallbackNotice: outcome == .inserted)
        switch outcome {
        case .inserted: break
        case .permissionRequired:
            showDeliveryNotice("文字已复制。辅助功能尚未授权或生效，请回到输入框按 ⌘V 粘贴。", authorize: true)
        case .copiedToClipboard:
            showDeliveryNotice("未能自动填入，文字已复制。请回到目标输入框按 ⌘V 粘贴。", authorize: accessibility.needsAttention)
        case .clipboardFailed:
            showDeliveryNotice("文字未能写入剪贴板，请点击重试复制。", authorize: accessibility.needsAttention, recoveryText: text)
        }
    }

    private func showDeliveryNotice(_ message: String, authorize: Bool, recoveryText: String? = nil) {
        deliveryNoticePanel?.orderOut(nil)
        let combined = [message, recordingViewModel.fallbackNotice].compactMap { $0 }.joined(separator: "\n")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dismiss: () -> Void = { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.deliveryNoticePanel === panel { self?.deliveryNoticePanel = nil }
        }
        let onAuthorize: (() -> Void)? = authorize ? { [weak self] in
            dismiss(); self?.showSettingsWindow(section: .permissions)
        } : nil
        let onCopy: (() -> Void)? = recoveryText.map { text in
            { [weak self] in
                let pb = NSPasteboard.general; pb.clearContents()
                if pb.setString(text, forType: .string) {
                    self?.showDeliveryNotice("文字已复制，请回到输入框按 ⌘V 粘贴。", authorize: self?.accessibility.needsAttention == true)
                }
            }
        }
        let host = NSHostingView(rootView: TextDeliveryNotice(message: combined, onAuthorize: onAuthorize,
                                                              onCopy: onCopy, onDismiss: dismiss))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 40))
        }
        deliveryNoticePanel = panel; panel.orderFront(nil)
        // Clipboard failures retain an explicit retry action until dismissed or the next recording.
        if recoveryText == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { dismiss() }
        }
    }

    private func cleanupAfterInjection(showFallbackNotice: Bool = true) {
        hotKeyService.stopEscapeMonitoring()
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
        hotKeyService.setBusy(false)
        stateManager.transition(to: .idle)
        if showFallbackNotice, let notice = recordingViewModel.fallbackNotice {
            showProcessingNotice(notice)
        }
    }

    /// 提示单独显示，不抢焦点、不混入输入正文，也不阻挡下一次录音。
    private func showProcessingNotice(_ message: String) {
        processingNoticePanel?.orderOut(nil)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 52),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView:
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 420, height: 52)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        )
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 40))
        }
        processingNoticePanel = panel
        panel.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard self?.processingNoticePanel === panel else { return }
            panel.orderOut(nil)
            self?.processingNoticePanel = nil
        }
    }

    // MARK: - Permissions

    private func setupAccessibilityMonitoring() {
        accessibilitySubscription = accessibility.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusItem()
        }
        accessibility.startMonitoring()
        updateStatusItem()
    }

    private func updateStatusItem() {
        let warning = hotKeyService.warning != nil || accessibility.needsAttention
        let update = AppUpdateService.shared.availableVersion.map { " · 新版本 \($0) 可更新" } ?? ""
        statusItem.button?.title = (warning ? " ⚠" : "") + (update.isEmpty ? "" : " ↑")
        let status = "Spoken · \(hotKeyService.displayName) · \(hotKeyService.statusText) · \(accessibility.state.statusText)" + update
        statusItem.button?.toolTip = status
        statusItem.button?.setAccessibilityLabel("Spoken，" + hotKeyService.accessibilityName + "，" + hotKeyService.statusText + "，" + accessibility.state.statusText + update)
    }

    private func checkPermissions() {
        SpeechService.shared.requestPermissions { [weak self] micGranted, speechGranted in
            guard let self else { return }
            if !micGranted || !speechGranted { self.showPermissionAlert() }
            self.accessibility.refresh()
            // Do not skip the text-input guide when another permission was denied.
            if self.accessibility.needsInitialGuide { self.showAccessibilityPermissionGuide() }
        }
    }

    private func showAccessibilityPermissionGuide() {
        guard !stateManager.isBusy(), accessibilityGuidePanel == nil else { return }
        let height = min(580, (NSScreen.main?.visibleFrame.height ?? 700) - 60)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Spoken · 完成自动输入设置"
        panel.delegate = self
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: AccessibilityGuideView(service: accessibility, onLater: { [weak self, weak panel] in
            panel?.close(); self?.accessibilityGuidePanel = nil
        }))
        panel.center()
        accessibilityGuidePanel = panel
        panel.orderFront(nil)
        accessibility.markGuidePresented()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要权限"
        alert.informativeText = "Spoken 需要麦克风和语音识别权限才能正常工作。请在系统设置中授权。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Recording ViewModel

@MainActor
class RecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isCaptureReady = false
    @Published var isAudioBuffered = false
    @Published var isCloudRecognizing = false
    @Published var isProcessing = false
    @Published var partialText = ""
    @Published var statusText = "正在准备麦克风，请稍候…"
    @Published var displayStatus = "录音"
    @Published var isCancelled = false
    @Published var hasDetectedSpeech = false
    @Published var hasRecoverableInput = false
    var onRecover: (() -> Void)?
    var canRecoverInput: Bool {
        hasRecoverableInput && isRecording && !isProcessing && !isCancelled
    }
    private(set) var fallbackNotice: String?
    private var recognitionFailure: String?
    private var frontmostApp: NSRunningApplication?
    var targetApplication: NSRunningApplication?
    private var lastRecognizedText = ""
    private let stateManager = StateManager.shared
    static let collapsedHeight: CGFloat = 224
    @Published var showsModes = false {
        didSet { onPanelResize?(panelHeight) }
    }
    var panelHeight: CGFloat { showsModes ? min(520, (NSScreen.main?.visibleFrame.height ?? 800) - 80) : Self.collapsedHeight }
    var onPanelResize: ((CGFloat) -> Void)?
    private(set) var frozenConfiguration: Result<AIProcessingSnapshot, Error>?
    private let snapshotProvider: () throws -> AIProcessingSnapshot
    private let modeNameProvider: () -> String
    private let processor: AIProcessingService
    private let stopCapture: () -> Void
    private let cancelCapture: () -> Void
    private let retainOriginal: (String, Bool) -> Void
    private var hasSubmitted = false

    init(snapshotProvider: @escaping () throws -> AIProcessingSnapshot = {
        try AIProcessingSnapshot.capture(modes: .shared, connections: .shared)
    }, modeNameProvider: @escaping () -> String = { ModeStore.shared.selected.name },
         processor: AIProcessingService = .shared,
         stopCapture: @escaping () -> Void = { SpeechService.shared.stopRecording() },
         cancelCapture: @escaping () -> Void = { SpeechService.shared.cancelRecording() },
         retainOriginal: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.snapshotProvider = snapshotProvider
        self.modeNameProvider = modeNameProvider
        self.processor = processor
        self.stopCapture = stopCapture
        self.cancelCapture = cancelCapture
        self.retainOriginal = retainOriginal
    }

    /// Called for both the stop button/hotkey and an automatic ASR finalization.
    func freezeConfiguration() {
        guard frozenConfiguration == nil else { return }
        frozenConfiguration = Result { try snapshotProvider() }
        showsModes = false
        switch frozenConfiguration! {
        case .success(let snapshot):
            displayStatus = snapshot.mode.name
        case .failure:
            displayStatus = modeNameProvider()
        }
        isProcessing = true
    }

    var onClose: (() -> Void)?
    var onComplete: ((String, NSRunningApplication?) -> Void)?
    var onCancel: (() -> Void)?
    var onRecognitionFailure: ((String) -> Void)?

    func startRecording() {
        frontmostApp = targetApplication ?? NSWorkspace.shared.frontmostApplication
        isRecording = true
        isCancelled = false
        frozenConfiguration = nil
        hasSubmitted = false
        showsModes = false
        isCaptureReady = false
        isAudioBuffered = false
        isProcessing = false
        hasDetectedSpeech = false
        fallbackNotice = nil
        recognitionFailure = nil
        partialText = ""
        lastRecognizedText = ""
        statusText = "正在准备麦克风，请稍候…"
        displayStatus = modeNameProvider()
        PipelineLatencyMetrics.shared.mark(.recordingStarted)

        stateManager.transition(to: .recording)

        let providerRaw = UserDefaults.standard.string(forKey: "speechRecognitionProvider") ?? SpeechRecognitionProvider.local.rawValue
        let provider = SpeechRecognitionProvider(rawValue: providerRaw) ?? .local
        if provider == .cloud || provider == .auto {
            isCloudRecognizing = true
        }

        SpeechService.shared.onCloudConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.isCloudRecognizing = true
            }
        }

        SpeechService.shared.onCloudPreparing = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRecording, self.partialText.isEmpty else { return }
                self.isCaptureReady = false
                self.statusText = self.isAudioBuffered
                    ? "正在连接云端，语音已暂存…"
                    : "正在连接云端，请稍候…"
            }
        }

        SpeechService.shared.onCloudConnectionFailed = { [weak self] reason in
            // SpeechService delivers this on main, before its final callback. Do not queue
            // it again, otherwise an incomplete transcript could enter AI processing first.
            self?.handleCloudRecognitionFailure(reason)
        }

        let started = SpeechService.shared.startRecording(
            onPartial: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self = self, self.isRecording else { return }
                    self.partialText = text
                    self.lastRecognizedText = text
                    if !text.isEmpty { self.isCaptureReady = true }
                    self.statusText = text.isEmpty
                        ? (self.isCaptureReady ? "可以开始说话，语音不会遗漏" : "正在准备麦克风，请稍候…")
                        : text
                }
            },
            onFinal: { [weak self] text in
                DispatchQueue.main.async {
                    guard let strongSelf = self, !strongSelf.isCancelled, !strongSelf.hasSubmitted else { return }
                    strongSelf.freezeConfiguration()
                    strongSelf.isRecording = false
                    strongSelf.isCaptureReady = false
                    strongSelf.isAudioBuffered = false
                    strongSelf.partialText = ""

                    strongSelf.statusText = ""
                    strongSelf.stateManager.transition(to: .finishing)
                    strongSelf.processAndInput(text.isEmpty ? strongSelf.lastRecognizedText : text)
                }
            },
            onRawFinal: { [weak self] text, incomplete in
                self?.retainRecognizedOriginal(text, mayBeIncomplete: incomplete)
            },
            onSpeechDetected: { [weak self] in
                guard let self, self.isRecording, !self.isCancelled else { return }
                self.hasDetectedSpeech = true
            },
            onAudioBuffered: { [weak self] in
                guard let self, self.isRecording, !self.isCancelled else { return }
                self.isAudioBuffered = true
                if self.partialText.isEmpty, !self.isCaptureReady {
                    self.statusText = "正在连接云端，语音已暂存…"
                }
            },
            onCaptureReady: { [weak self] in
                guard let self, self.isRecording, !self.isCancelled else { return }
                self.isCaptureReady = true
                if self.partialText.isEmpty {
                    self.statusText = "可以开始说话，语音不会遗漏"
                }
            },
            onCaptureStopped: { [weak self] in
                // SpeechService stops capture on the main thread, before awaiting final ASR.
                self?.captureStopped()
            },
            onStartFailure: { [weak self] reason in
                DispatchQueue.main.async {
                    guard let self, !self.isCancelled else { return }
                    self.isRecording = false
                    self.isCaptureReady = false
                    self.isAudioBuffered = false
                    self.isCloudRecognizing = false
                    self.isProcessing = false
                    self.statusText = reason
                    self.stateManager.transition(to: .idle)
                    self.onRecognitionFailure?(reason)
                    self.onCancel?()
                }
            }
        )

        if !started {
            isRecording = false
            isCaptureReady = false
            isAudioBuffered = false
            isCloudRecognizing = false
            statusText = "录音启动失败，请重试"
            stateManager.transition(to: .idle)
            onCancel?()
        }
    }

    func cancel() {
        if isCancelled { return }
        isCancelled = true

        cancelCapture()
        processor.cancelCurrentTask()

        statusText = "已取消"
        isRecording = false
        isCaptureReady = false
        isAudioBuffered = false
        isCloudRecognizing = false
        isProcessing = false
        PipelineLatencyMetrics.shared.abandon()

        onCancel?()
    }

    func retainRecognizedOriginal(_ text: String, mayBeIncomplete: Bool) {
        guard !isCancelled, !hasSubmitted else { return }
        if mayBeIncomplete, recognitionFailure == nil {
            recognitionFailure = "语音识别未完整结束"
        }
        retainOriginal(text, mayBeIncomplete || recognitionFailure != nil)
    }

    func stopRecording() {
        guard isRecording else { return }
        captureStopped()
        stopCapture()
    }

    func captureStopped() {
        guard !isCancelled, !hasSubmitted else { return }
        freezeConfiguration()
        isRecording = false
        isCaptureReady = false
        isAudioBuffered = false
        isCloudRecognizing = false
        statusText = ""

        stateManager.transition(to: .finishing)
    }

    func processAndInput(_ text: String) {
        guard !isCancelled, !hasSubmitted else { return }
        hasSubmitted = true
        guard !text.isEmpty else {
            isProcessing = false
            if let recognitionFailure {
                statusText = "语音识别失败：" + recognitionFailure
                onRecognitionFailure?(statusText)
            }
            stateManager.transition(to: .idle)
            PipelineLatencyMetrics.shared.abandon()
            onCancel?()
            return
        }
        if recognitionFailure != nil {
            isProcessing = false
            fallbackNotice = "语音识别未完整结束，已保留已识别文字，请核对是否有遗漏。"
            onComplete?(text, frontmostApp)
            return
        }
        freezeConfiguration()
        switch frozenConfiguration! {
        case .failure(let error): finishAIProcessing(.failure(error), originalText: text)
        case .success(let snapshot):
            isProcessing = true
            processor.process(text: text, snapshot: snapshot) { [weak self] result in
                DispatchQueue.main.async { self?.finishAIProcessing(result, originalText: text) }
            }
        }
    }

    func handleCloudRecognitionFailure(_ reason: String) {
        guard !isCancelled, !hasSubmitted else { return }
        if !isRecording && isProcessing {
            recognitionFailure = reason
            statusText = "云端识别未完成，正在保留已有文字…"
        } else if isRecording && isCloudRecognizing && partialText.isEmpty {
            let raw = UserDefaults.standard.string(forKey: "speechRecognitionProvider")
            let provider = SpeechRecognitionProvider(rawValue: raw ?? "") ?? .local
            statusText = provider == .auto ? "云端连接失败，正在尝试本地识别" : "云端连接失败，请重试"
        }
    }

    func finishAIProcessing(_ result: Result<String, Error>, originalText: String) {
        guard !isCancelled else { return }
        isProcessing = false
        fallbackNotice = nil
        let finalText: String
        let snapshot = try? frozenConfiguration?.get()
        let validated = result.flatMap { output -> Result<String, Error> in
            AIProcessingService.validatedOutput(output, stripWrappers: snapshot?.mode.isCustom != true,
                isInstruction: snapshot?.mode.builtin == .aiInstruction, originalText: originalText)
        }
        switch validated {
        case .success(let output):
            finalText = output
        case .failure(let error):
            fallbackNotice = MiniMaxError.fallbackNotice(for: error)
            finalText = originalText
        }
        onComplete?(finalText, frontmostApp)
    }
}

// MARK: - Recording Panel View

struct RecordingPanelView: View {
    static let width: CGFloat = 420
    @ObservedObject var viewModel: RecordingViewModel
    @ObservedObject var modes: ModeStore
    @ObservedObject var hotkeys: HotKeyService
    @ObservedObject var accessibility: AccessibilityPermissionService
    @State private var modeError: String?

    init(viewModel: RecordingViewModel, modes: ModeStore = .shared, hotkeys: HotKeyService? = nil, accessibility: AccessibilityPermissionService? = nil) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _modes = ObservedObject(wrappedValue: modes)
        _hotkeys = ObservedObject(wrappedValue: hotkeys ?? .shared)
        _accessibility = ObservedObject(wrappedValue: accessibility ?? .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spoken").font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                if accessibility.needsAttention {
                    Text("需手动粘贴").font(.caption).foregroundStyle(.orange)
                        .help("辅助功能尚未授权或生效，完成后请按 Command V 粘贴文字")
                        .accessibilityLabel("辅助功能尚未授权或生效，结果需要手动粘贴")
                }
                Circle().fill(viewModel.isRecording ? (viewModel.isCaptureReady ? Color.green : Color.orange) : SpokenTheme.accent)
                    .frame(width: 6, height: 6)
                Text(viewModel.isRecording ? (viewModel.isCaptureReady ? "可说话" : "准备中") : "处理中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                viewModel.showsModes.toggle()
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text(viewModel.isRecording ? modes.selected.name : viewModel.displayStatus).lineLimit(1)
                    Spacer()
                    Image(systemName: viewModel.isRecording ? (viewModel.showsModes ? "chevron.up" : "chevron.down") : "lock.fill")
                }.font(.callout).padding(10)
                    .background(SpokenTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).disabled(!viewModel.isRecording)
                .accessibilityLabel("当前模式：\(viewModel.isRecording ? modes.selected.name : viewModel.displayStatus)")
                .help(viewModel.isRecording ? "录音中可以切换，停止时锁定" : "本次模式已锁定")
            if viewModel.showsModes && viewModel.isRecording {
                ScrollView {
                    ModeGrid(modes: modes.modes, selectedID: modes.selected.id, onSelect: { id in
                        do { try modes.select(id); viewModel.showsModes = false; modeError = nil }
                        catch { modeError = error.localizedDescription }
                    })
                }.frame(maxHeight: .infinity)
            }
            WaveformView(isRecording: viewModel.isRecording && (viewModel.isCaptureReady || viewModel.isAudioBuffered),
                         isCloudRecognizing: viewModel.isCloudRecognizing && viewModel.isCaptureReady,
                         isProcessing: viewModel.isProcessing).frame(height: 40)
            Text(modeError ?? viewModel.statusText).font(.system(size: 13)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { viewModel.onRecover?() } label: {
                    Label("找回上次输入", systemImage: "arrow.uturn.backward")
                }.controlSize(.small)
                    .disabled(!viewModel.canRecoverInput)
                    .help(!viewModel.hasRecoverableInput ? "暂无可找回的上次输入" : (viewModel.canRecoverInput ? "取消本轮录音并找回上次输入" : "正在处理或已取消，请重新唤起录音后找回"))
                Spacer(minLength: 0)
                Text(hotkeys.isRegistered ? "\(hotkeys.displayName)\(viewModel.isRecording ? "完成" : "取消") · Esc 取消" : "快捷键不可用 · Esc 取消")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Button("取消") { viewModel.cancel() }.controlSize(.small)
                    .disabled(viewModel.isCancelled)
            }
        }.padding(18).frame(width: Self.width, height: viewModel.panelHeight)
            .background(SpokenTheme.background, in: RoundedRectangle(cornerRadius: 16))
            .tint(SpokenTheme.accent)
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let isRecording: Bool
    let isCloudRecognizing: Bool
    let isProcessing: Bool

    @State private var barHeights: [CGFloat] = Array(repeating: 6, count: 24)
    @State private var timer: Timer?

    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barHeights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(waveformColor)
                    .frame(width: barWidth, height: max(4, barHeights[index]))
                    .animation(.spring(response: 0.2, dampingFraction: 0.5), value: barHeights[index])
            }
        }
        .frame(height: 48)
        .onAppear {
            if isRecording || isCloudRecognizing {
                startAnimation()
            }
        }
        .onDisappear { stopAnimation() }
        .onChange(of: isRecording) { _, newValue in
            if newValue || isCloudRecognizing {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
        .onChange(of: isCloudRecognizing) { _, newValue in
            if newValue || isRecording {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
    }

    private var waveformColor: LinearGradient {
        if isProcessing {
            return LinearGradient(
                colors: [Color(hex: "#f39c12"), Color(hex: "#e67e22")],
                startPoint: .bottom,
                endPoint: .top
            )
        } else if isCloudRecognizing {
            return LinearGradient(
                colors: [Color(hex: "#4a90d9"), Color(hex: "#2980b9")],
                startPoint: .bottom,
                endPoint: .top
            )
        } else if isRecording {
            return LinearGradient(
                colors: [Color(hex: "#c0392b"), Color(hex: "#e74c3c")],
                startPoint: .bottom,
                endPoint: .top
            )
        } else {
            return LinearGradient(
                colors: [Color(hex: "#4e4e4e"), Color(hex: "#6e6e6e")],
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            DispatchQueue.main.async {
                for i in 0..<barHeights.count {
                    let center = CGFloat(barHeights.count) / 2.0
                    let distance = abs(CGFloat(i) - center) / center
                    let maxH = 40.0 * (1.0 - distance * 0.3)
                    barHeights[i] = CGFloat.random(in: 6...maxH)
                }
            }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        barHeights = Array(repeating: 6, count: barHeights.count)
    }
}
