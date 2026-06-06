import AppKit
import SwiftUI

extension Notification.Name {
    static let spokenPopoverResize = Notification.Name("com.moss.Spoken.popoverResize")
}

enum AppState: String, CaseIterable {
    case idle
    case starting
    case recording
    case cloudRecognizing
    case finishing
    case injecting
    case postProcessing
}

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

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyService: HotKeyService!
    private var recordingPanel: NSPanel?
    private var recordingViewModel = RecordingViewModel()
    private var frontmostAppBeforeHotKey: NSRunningApplication?
    private let stateManager = StateManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupHotKey()
        checkPermissions()
    }

    // MARK: - Status Item

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
        let contentView = ContentView()
        popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        NotificationCenter.default.addObserver(
            forName: .spokenPopoverResize,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let showSettings = notification.userInfo?["showSettings"] as? Bool ?? false
            let newSize = showSettings ? NSSize(width: 420, height: 460) : NSSize(width: 260, height: 200)
            self.popover.contentSize = newSize
            // 如果 popover 正在显示，需要调整位置以匹配新大小
            if self.popover.isShown, let button = self.statusItem.button {
                self.popover.performClose(nil)
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Global HotKey

    private func setupHotKey() {
        hotKeyService = HotKeyService.shared
        hotKeyService.onTriggered = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotKey()
            }
        }
        hotKeyService.onEscape = { [weak self] in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                if strongSelf.recordingPanel?.isVisible == true {
                    strongSelf.recordingViewModel.cancel()
                }
            }
        }
        hotKeyService.registerAll()
    }

    private func handleHotKey() {
        if popover.isShown {
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
        SpeechService.shared.prepareCloudConnection()
        showRecordingPanel()
    }

    // MARK: - Recording Panel

    private func showRecordingPanel() {
        frontmostAppBeforeHotKey = NSWorkspace.shared.frontmostApplication
        print("Spoken: [DEBUG] AppDelegate frontmost app saved: \(frontmostAppBeforeHotKey?.localizedName ?? "unknown")")

        stateManager.transition(to: .starting)

        let viewModel = RecordingViewModel()
        let recordingView = RecordingPanelView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: recordingView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
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

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.origin.y + 40
            ))
        }

        viewModel.onCancel = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.stateManager.transition(to: .idle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                strongSelf.recordingPanel?.orderOut(nil)
                strongSelf.recordingPanel = nil
            }
        }

        viewModel.onClose = { [weak self] in
            self?.recordingPanel?.orderOut(nil)
            self?.recordingPanel = nil
        }

        viewModel.onComplete = { [weak self] text, appFromViewModel in
            guard let strongSelf = self else { return }
            let targetApp = appFromViewModel ?? strongSelf.frontmostAppBeforeHotKey
            strongSelf.performTextInjection(text: text, targetApp: targetApp)
        }

        self.recordingViewModel = viewModel
        self.recordingPanel = panel
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            viewModel.startRecording()
        }
    }

    // MARK: - Text Injection

    private func performTextInjection(text: String, targetApp: NSRunningApplication?) {
        print("Spoken: [DEBUG] performTextInjection - text length: \(text.count)")
        stateManager.transition(to: .injecting)

        recordingPanel?.orderOut(nil)

        if let app = targetApp {
            print("Spoken: [DEBUG] Activating: \(app.localizedName ?? "unknown")")
            app.activate(options: [.activateAllWindows])
        } else {
            print("Spoken: [WARN] No target app found")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.executeInjection(text: text)
        }
    }

    private func executeInjection(text: String) {
        print("Spoken: [DEBUG] frontmost app before inject: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")

        let success = KeyboardService.shared.typeText(text)
        print("Spoken: [DEBUG] injection success: \(success)")

        if !success {
            print("Spoken: [WARN] Keyboard injection failed, copying to clipboard as fallback")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        cleanupAfterInjection()
    }

    private func cleanupAfterInjection() {
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
        stateManager.transition(to: .idle)
    }

    // MARK: - Permissions

    private func checkPermissions() {
        SpeechService.shared.requestPermissions { micGranted, speechGranted in
            let accessibilityGranted = AXIsProcessTrusted()
            print("Spoken: [DEBUG] AXIsProcessTrusted at startup: \(accessibilityGranted)")

            if !micGranted || !speechGranted {
                DispatchQueue.main.async {
                    self.showPermissionAlert()
                }
            } else if !accessibilityGranted {
                DispatchQueue.main.async {
                    self.showAccessibilityPermissionGuide()
                }
            }
        }
    }

    private func showAccessibilityPermissionGuide() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        Spoken 需要辅助功能权限才能将识别的文字自动输入到目标应用。
        
        请按以下步骤操作：
        1. 点击下方"打开系统设置"
        2. 在"辅助功能"列表中找到 Spoken 并开启
        3. 如果列表中没有 Spoken，请先关闭再重新打开开关
        4. 授权后需要重新启动 Spoken
        
        注意：每次从 Xcode 重新编译后，需要重新授权。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后设置")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
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

class RecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isCloudRecognizing = false
    @Published var isProcessing = false
    @Published var partialText = ""
    @Published var statusText = "正在聆听..."
    @Published var displayStatus = "录音"
    @Published var isCancelled = false
    private var frontmostApp: NSRunningApplication?
    private var lastRecognizedText = ""
    private let stateManager = StateManager.shared

    var onClose: (() -> Void)?
    var onComplete: ((String, NSRunningApplication?) -> Void)?
    var onCancel: (() -> Void)?

    func startRecording() {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        isRecording = true
        isProcessing = false
        partialText = ""
        lastRecognizedText = ""
        statusText = "正在聆听..."
        displayStatus = "录音"

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

        let started = SpeechService.shared.startRecording(
            onPartial: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self = self, self.isRecording else { return }
                    self.partialText = text
                    self.lastRecognizedText = text
                    self.statusText = text.isEmpty ? "正在聆听..." : text
                }
            },
            onFinal: { [weak self] text in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    strongSelf.isRecording = false
                    strongSelf.partialText = ""

                    let modeRaw = UserDefaults.standard.string(forKey: "spokenMode") ?? "直接输入"
                    let mode = SpokenMode(rawValue: modeRaw) ?? .direct

                    if mode == .direct {
                        strongSelf.isProcessing = false
                        strongSelf.statusText = ""
                    } else {
                        strongSelf.isProcessing = true
                        strongSelf.displayStatus = mode.rawValue
                        strongSelf.statusText = ""
                    }

                    strongSelf.stateManager.transition(to: .finishing)
                    strongSelf.processAndInput(text.isEmpty ? strongSelf.lastRecognizedText : text)
                }
            }
        )

        if !started {
            isRecording = false
            isCloudRecognizing = false
            statusText = "录音启动失败，请重试"
            stateManager.transition(to: .idle)
        }
    }

    func cancel() {
        if isCancelled { return }
        isCancelled = true

        SpeechService.shared.cancelRecording()
        MiniMaxService.shared.cancelCurrentTask()

        statusText = "已取消"
        isRecording = false
        isCloudRecognizing = false
        isProcessing = false

        onCancel?()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isCloudRecognizing = false
        statusText = ""

        let modeRaw = UserDefaults.standard.string(forKey: "spokenMode") ?? "直接输入"
        let mode = SpokenMode(rawValue: modeRaw) ?? .direct

        if mode == .direct {
            isProcessing = false
        } else {
            isProcessing = true
            displayStatus = mode.rawValue
        }

        stateManager.transition(to: .finishing)
        SpeechService.shared.stopRecording()
    }

    private func processAndInput(_ text: String) {
        print("Spoken: [DEBUG] processAndInput called with text length: \(text.count)")

        guard !text.isEmpty else {
            print("Spoken: [WARN] processAndInput: empty text received")
            isProcessing = false
            stateManager.transition(to: .idle)
            return
        }

        let modeRaw = UserDefaults.standard.string(forKey: "spokenMode") ?? "直接输入"
        let mode = SpokenMode(rawValue: modeRaw) ?? .direct
        let translateLangRaw = UserDefaults.standard.string(forKey: "translateLang") ?? "英文"
        let translateLang = TranslateLanguage(rawValue: translateLangRaw) ?? .english

        print("Spoken: [DEBUG] Process mode: \(mode.rawValue), translateLang: \(translateLang.rawValue)")

        if mode == .direct {
            print("Spoken: [DEBUG] Direct mode, skipping AI processing")
            isProcessing = false
            onComplete?(text, frontmostApp)
            return
        }

        print("Spoken: [DEBUG] Starting AI processing: \(mode.rawValue)")
        isProcessing = true

        MiniMaxService.shared.process(
            text: text,
            mode: mode,
            translateLang: translateLang
        ) { [weak self] result in
            guard let strongSelf = self else {
                print("Spoken: [ERROR] processAndInput: self is nil in completion")
                return
            }

            DispatchQueue.main.async {
                strongSelf.isProcessing = false
                let finalText: String

                switch result {
                case .success(let output):
                    if output.isEmpty {
                        print("Spoken: [DEBUG] AI returned empty output, using original text")
                        finalText = text
                    } else {
                        print("Spoken: [DEBUG] AI processing succeeded, output length: \(output.count)")
                        finalText = output
                    }

                case .failure(let error):
                    print("Spoken: [ERROR] AI processing failed: \(error.localizedDescription)")
                    print("Spoken: [DEBUG] Falling back to original text (length: \(text.count))")
                    finalText = text
                }

                print("Spoken: [DEBUG] Calling onComplete with text length: \(finalText.count)")
                strongSelf.onComplete?(finalText, strongSelf.frontmostApp)
            }
        }
    }
}

// MARK: - Recording Panel View

struct RecordingPanelView: View {
    @ObservedObject var viewModel: RecordingViewModel
    @State private var pulseScale: CGFloat = 1.0

    private let bgPrimary = Color(hex: "#ffffff")
    private let textPrimary = Color(hex: "#000000")
    private let textSecondary = Color(hex: "#4e4e4e")
    private let textMuted = Color(hex: "#777169")
    private let warmShadow = Color(hex: "#4e3220")

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Spoken")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.14)
                    .foregroundColor(textSecondary)

                Text("·")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(textMuted)

                Text("语言是最好的输入")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(textMuted)
                    .tracking(0.14)

                Spacer()

                if viewModel.isRecording {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: "#c0392b"))
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulseScale)
                            .animation(
                                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                value: pulseScale
                            )
                        Text("录音")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.14)
                            .foregroundColor(Color(hex: "#c0392b"))
                    }
                    .onAppear {
                        pulseScale = 1.0
                        withAnimation { pulseScale = 1.3 }
                    }
                } else if viewModel.isCloudRecognizing {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: "#4a90d9"))
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulseScale)
                            .animation(
                                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                value: pulseScale
                            )
                        Text("云端识别中...")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.14)
                            .foregroundColor(Color(hex: "#4a90d9"))
                    }
                    .onAppear {
                        pulseScale = 1.0
                        withAnimation { pulseScale = 1.3 }
                    }
                } else if viewModel.isProcessing {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: "#f39c12"))
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulseScale)
                            .animation(
                                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                value: pulseScale
                            )
                        Text(viewModel.displayStatus)
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.14)
                            .foregroundColor(Color(hex: "#f39c12"))
                    }
                    .onAppear {
                        pulseScale = 1.0
                        withAnimation { pulseScale = 1.2 }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer().frame(height: 12)

            WaveformView(
                isRecording: viewModel.isRecording,
                isCloudRecognizing: viewModel.isCloudRecognizing,
                isProcessing: viewModel.isProcessing
            )
            .frame(height: 48)

            Spacer().frame(height: 14)

            Text(viewModel.statusText)
                .font(.system(size: 15, weight: .regular))
                .tracking(0.16)
                .foregroundColor(viewModel.partialText.isEmpty ? textMuted : textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.2), value: viewModel.statusText)

            Spacer().frame(height: 14)

            HStack {
                if viewModel.isCancelled {
                    Text("已取消")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.14)
                        .foregroundColor(textMuted)
                } else if viewModel.isRecording {
                    HStack(spacing: 10) {
                        Text("再次按 ⌥+空格 结束")
                            .font(.system(size: 11, weight: .regular))
                            .tracking(0.14)
                            .foregroundColor(textMuted)
                        Spacer()
                        Button("取消") {
                            viewModel.cancel()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#c0392b"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(hex: "#f5f2ef"))
                        .cornerRadius(6)
                        .buttonStyle(.plain)
                    }
                } else if viewModel.isCloudRecognizing || viewModel.isProcessing {
                    HStack(spacing: 10) {
                        Spacer()
                        Button("取消") {
                            viewModel.cancel()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#c0392b"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(hex: "#f5f2ef"))
                        .cornerRadius(6)
                        .buttonStyle(.plain)
                    }
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(width: 420, height: 170)
        .background(
            bgPrimary
                .cornerRadius(16)
                .shadow(color: warmShadow.opacity(0.04), radius: 4, x: 0, y: 2)
                .shadow(color: warmShadow.opacity(0.02), radius: 1, x: 0, y: 0)
        )
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
