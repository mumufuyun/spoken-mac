import AppKit
import SwiftUI

enum AppState: String, CaseIterable {
    case idle
    case starting
    case recording
    case finishing
    case injecting
    case postProcessing
}

class StateManager: ObservableObject {
    static let shared = StateManager()
    
    @Published var currentState: AppState = .idle
    
    private init() {}
    
    func transition(to newState: AppState) {
        guard currentState != newState else {
            print("Spoken: [DEBUG] Skipping duplicate state transition: \(newState.rawValue)")
            return
        }
        guard !isBusy() || newState == .idle else {
            print("Spoken: [DEBUG] Blocking transition during processing: \(currentState.rawValue) -> \(newState.rawValue)")
            return
        }
        print("Spoken: [DEBUG] State transition: \(currentState.rawValue) -> \(newState.rawValue)")
        currentState = newState
    }
    
    private func isBusy() -> Bool {
        return [.finishing, .injecting, .postProcessing].contains(currentState)
    }
    
    func isIdle() -> Bool {
        return currentState == .idle
    }
    
    func isRecording() -> Bool {
        return currentState == .recording
    }
    
    func isProcessing() -> Bool {
        return [.starting, .finishing, .injecting, .postProcessing].contains(currentState)
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
        hotKeyService.register()
    }

    private func handleHotKey() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if recordingPanel?.isVisible == true {
            // 用户再次按快捷键，停止录音但保持面板显示
            recordingViewModel.stopRecording()
            // 不要隐藏面板，等待注入完成后再隐藏
            return
        }
        showRecordingPanel()
    }
    
    private func closeRecordingPanel() {
        // 停止录音，这会触发 onComplete 回调
        recordingViewModel.stopRecording()
        // 隐藏录音面板
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
    }

    // MARK: - Recording Panel

    private func showRecordingPanel() {
        // 保存当前前台应用
        frontmostAppBeforeHotKey = NSWorkspace.shared.frontmostApplication
        print("Spoken: [DEBUG] AppDelegate frontmost app saved: \(frontmostAppBeforeHotKey?.localizedName ?? "unknown")")
        
        // 状态转换：idle -> starting
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

        // 底部居中
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.origin.y + 40
            ))
        }

        viewModel.onClose = { [weak self] in
            self?.closeRecordingPanel()
        }

        viewModel.onComplete = { [weak self] text, appFromViewModel in
            guard let strongSelf = self else { return }
            let savedFrontmostApp = appFromViewModel ?? strongSelf.frontmostAppBeforeHotKey
            let textToInject = text
            
            print("Spoken: [DEBUG] AppDelegate onComplete - text: \(textToInject)")
            print("Spoken: [DEBUG] AppDelegate onComplete - saved frontmost app: \(savedFrontmostApp?.localizedName ?? "unknown")")
            
            // 状态转换：finishing -> injecting
            strongSelf.stateManager.transition(to: .injecting)
            
            if let app = savedFrontmostApp {
                print("Spoken: [DEBUG] will activate: \(app.localizedName ?? "unknown") (PID: \(app.processIdentifier))")
                
                // 激活目标应用
                let activateResult = app.activate()
                print("Spoken: [DEBUG] activate returned: \(activateResult)")
                print("Spoken: [DEBUG] current frontmost after activate: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
                
                // 缩短等待时间，检测到应用在前台后立即注入
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let frontmostNow = NSWorkspace.shared.frontmostApplication
                    print("Spoken: [DEBUG] frontmost app before inject: \(frontmostNow?.localizedName ?? "none")")
                    print("Spoken: [DEBUG] injecting text: \(textToInject)")
                    let success = KeyboardService.shared.typeText(textToInject)
                    print("Spoken: [DEBUG] injection success: \(success)")
                    
                    // 注入完成后显示完成状态，短暂停留后消失
                    DispatchQueue.main.async {
                        strongSelf.recordingViewModel.statusText = "已完成 ✓"
                        strongSelf.recordingViewModel.isProcessing = false
                        strongSelf.recordingViewModel.isRecording = false
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        strongSelf.recordingPanel?.orderOut(nil)
                        strongSelf.recordingPanel = nil
                        strongSelf.stateManager.transition(to: .postProcessing)
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            strongSelf.stateManager.transition(to: .idle)
                        }
                    }
                }
            } else {
                print("Spoken: [DEBUG] no saved app, injecting directly")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let success = KeyboardService.shared.typeText(textToInject)
                    print("Spoken: [DEBUG] injection success: \(success)")
                    
                    // 注入完成后显示完成状态，短暂停留后消失
                    DispatchQueue.main.async {
                        strongSelf.recordingViewModel.statusText = "已完成 ✓"
                        strongSelf.recordingViewModel.isProcessing = false
                        strongSelf.recordingViewModel.isRecording = false
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        strongSelf.recordingPanel?.orderOut(nil)
                        strongSelf.recordingPanel = nil
                        strongSelf.stateManager.transition(to: .postProcessing)
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            strongSelf.stateManager.transition(to: .idle)
                        }
                    }
                }
            }
        }

        self.recordingViewModel = viewModel
        self.recordingPanel = panel
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            viewModel.startRecording()
        }
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
    @Published var isProcessing = false
    @Published var partialText = ""
    @Published var statusText = "正在聆听..."
    private var frontmostApp: NSRunningApplication?
    private var lastRecognizedText = ""
    private let stateManager = StateManager.shared

    var onClose: (() -> Void)?
    var onComplete: ((String, NSRunningApplication?) -> Void)?

    func startRecording() {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        isRecording = true
        isProcessing = false
        partialText = ""
        lastRecognizedText = ""
        statusText = "正在聆听..."
        
        // 状态转换：starting -> recording
        stateManager.transition(to: .recording)

        SpeechService.shared.startRecording(
            onPartial: { [weak self] text in
                DispatchQueue.main.async {
                    self?.partialText = text
                    self?.lastRecognizedText = text
                    self?.statusText = text.isEmpty ? "正在聆听..." : text
                }
            },
            onFinal: { [weak self] text in
                DispatchQueue.main.async {
                    self?.isRecording = false
                    self?.isProcessing = true
                    self?.partialText = ""
                    self?.statusText = "正在识别..."
                    // 状态转换：recording -> finishing
                    self?.stateManager.transition(to: .finishing)
                    self?.processAndInput(text.isEmpty ? (self?.lastRecognizedText ?? "") : text)
                }
            }
        )
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        statusText = "正在识别..."
        // 状态转换：recording -> finishing（StateManager 会防止重复转换）
        stateManager.transition(to: .finishing)
        SpeechService.shared.stopRecording()
        // 不调用 processAndInput，等待 SpeechService 的 onFinal 回调
    }

    private func processAndInput(_ text: String) {
        guard !text.isEmpty else {
            statusText = "未识别到内容"
            isProcessing = false
            stateManager.transition(to: .idle)
            return
        }

        let modeRaw = UserDefaults.standard.string(forKey: "spokenMode") ?? "直接输入"
        let mode = SpokenMode(rawValue: modeRaw) ?? .direct
        let translateLangRaw = UserDefaults.standard.string(forKey: "translateLang") ?? "英文"
        let translateLang = TranslateLanguage(rawValue: translateLangRaw) ?? .english

        print("Spoken: [DEBUG] Process mode from UserDefaults: \(mode.rawValue), translateLang: \(translateLang.rawValue)")

        if mode == .direct {
            statusText = "已完成"
            isProcessing = false
            onComplete?(text, frontmostApp)
            return
        }

        statusText = mode == .polish ? "润色中..." :
                     mode == .prompt ? "生成 Prompt..." :
                     mode == .translate ? "翻译中..." :
                     mode == .summarize ? "摘要中..." : "格式化中..."
        isProcessing = true

        MiniMaxService.shared.process(
            text: text,
            mode: mode,
            translateLang: translateLang
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessing = false
                let finalText: String
                switch result {
                case .success(let output):
                    finalText = output.isEmpty ? text : output
                    self?.statusText = "\(mode.rawValue)完成"
                    print("Spoken: [DEBUG] AI processed text: \(finalText)")
                case .failure(let error):
                    print("Spoken: [ERROR] AI processing failed: \(error.localizedDescription)")
                    finalText = text
                    self?.statusText = "AI 处理失败，使用原文"
                }
                self?.onComplete?(finalText, self?.frontmostApp)
            }
        }
    }
}

// MARK: - Recording Panel View

struct RecordingPanelView: View {
    @ObservedObject var viewModel: RecordingViewModel
    @State private var pulseScale: CGFloat = 1.0

    // ElevenLabs Warm Palette
    private let bgPrimary = Color(hex: "#ffffff")
    private let warmStone = Color(hex: "#f5f2ef")
    private let textPrimary = Color(hex: "#000000")
    private let textSecondary = Color(hex: "#4e4e4e")
    private let textMuted = Color(hex: "#777169")
    private let warmShadow = Color(hex: "#4e3220")

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text("Spoken")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.14)
                    .foregroundColor(textSecondary)

                Spacer()

                // 录音指示 - ElevenLabs 风格圆点
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
                        Text("录音中")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.14)
                            .foregroundColor(Color(hex: "#c0392b"))
                    }
                    .onAppear {
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
                        Text(viewModel.statusText)
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.14)
                            .foregroundColor(Color(hex: "#f39c12"))
                    }
                    .onAppear {
                        withAnimation { pulseScale = 1.2 }
                    }
                } else if viewModel.statusText.contains("完成") || viewModel.statusText.contains("✓") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: "#27ae60"))
                            .frame(width: 6, height: 6)
                        Text("已完成")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.14)
                            .foregroundColor(Color(hex: "#27ae60"))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer().frame(height: 12)

            // 波形动画 - ElevenLabs 暖色调
            WaveformView(
                isRecording: viewModel.isRecording,
                isProcessing: viewModel.isProcessing,
                partialText: viewModel.partialText
            )
            .frame(height: 48)

            Spacer().frame(height: 14)

            // 识别文本
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

            // 底部提示
            HStack {
                if viewModel.isProcessing {
                    Text("AI 处理中...")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.14)
                        .foregroundColor(Color(hex: "#f39c12"))
                } else if viewModel.isRecording {
                    Text("再次按 ⌥+空格 结束录音")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.14)
                        .foregroundColor(textMuted)
                } else {
                    Text("按 ⌥+空格 开始录音")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.14)
                        .foregroundColor(textMuted)
                }

                Spacer()

                Button(action: { viewModel.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(textMuted.opacity(0.5))
                }
                .buttonStyle(.plain)
                .opacity(viewModel.isRecording ? 0.4 : 1)
                .disabled(viewModel.isRecording)
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

// MARK: - 波形动画条

struct WaveBar: View {
    let index: Int
    let isRecording: Bool

    @State private var animHeight: CGFloat = 6

    private let barWidth: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: isRecording
                        ? [Color(hex: "#c0392b"), Color(hex: "#e74c3c")]
                        : [Color(hex: "#4e4e4e"), Color(hex: "#6e6e6e")],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: barWidth, height: animHeight)
            .animation(
                .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.1),
                value: animHeight
            )
            .onAppear {
                if isRecording {
                    animHeight = CGFloat.random(in: 10...32)
                }
            }
            .onChange(of: isRecording) { _, newValue in
                if newValue {
                    animHeight = CGFloat.random(in: 10...32)
                } else {
                    animHeight = 6
                }
            }
    }
}

// MARK: - 波形动画视图

struct WaveformView: View {
    let isRecording: Bool
    let isProcessing: Bool
    let partialText: String

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
            if isRecording {
                startAnimation()
            }
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue {
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

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
