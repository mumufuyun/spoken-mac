import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyService: HotKeyService!
    private var recordingPanel: NSPanel?
    private var recordingViewModel = RecordingViewModel()
    private var frontmostAppBeforeHotKey: NSRunningApplication?

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
        hotKeyService = HotKeyService()
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
            // 关闭录音面板，并停止录音
            closeRecordingPanel()
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
            self?.closeRecordingPanel()
            guard let strongSelf = self else { return }
            let savedFrontmostApp = appFromViewModel ?? strongSelf.frontmostAppBeforeHotKey
            let textToInject = text
            
            print("Spoken: [DEBUG] AppDelegate onComplete - text: \(textToInject)")
            print("Spoken: [DEBUG] AppDelegate onComplete - frontmost app: \(savedFrontmostApp?.localizedName ?? "unknown")")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let app = savedFrontmostApp {
                    print("Spoken: [DEBUG] activating frontmost app: \(app.localizedName ?? "unknown")")
                    app.activate(options: [.activateIgnoringOtherApps])
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        print("Spoken: [DEBUG] injecting text: \(textToInject)")
                        _ = KeyboardService.shared.typeText(textToInject)
                        NotificationService.shared.notifySuccess(text: textToInject)
                    }
                } else {
                    print("Spoken: [DEBUG] injecting text directly: \(textToInject)")
                    _ = KeyboardService.shared.typeText(textToInject)
                    NotificationService.shared.notifySuccess(text: textToInject)
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
            // 检查辅助功能权限
            let accessibilityGranted = AccessibilityService.shared.isAccessibilityEnabled()
            
            if !micGranted || !speechGranted {
                DispatchQueue.main.async {
                    self.showPermissionAlert()
                }
            } else if !accessibilityGranted {
                // 请求辅助功能权限
                DispatchQueue.main.async {
                    AccessibilityService.shared.requestAccessibilityPermission()
                }
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
    @Published var partialText = ""
    @Published var statusText = "正在聆听..."
    private var frontmostApp: NSRunningApplication?
    private var lastRecognizedText = ""

    var onClose: (() -> Void)?
    var onComplete: ((String, NSRunningApplication?) -> Void)?

    func startRecording() {
        // 保存当前前台应用
        frontmostApp = NSWorkspace.shared.frontmostApplication
        print("Spoken: [DEBUG] RecordingViewModel frontmost app saved: \(frontmostApp?.localizedName ?? "unknown")")
        
        isRecording = true
        partialText = ""
        lastRecognizedText = ""
        statusText = "正在聆听..."

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
                    self?.partialText = ""
                    self?.processAndInput(text)
                }
            }
        )
    }

    func stopRecording() {
        statusText = "正在识别..."
        
        // 使用新版的 stopRecording 方法，传入 onFinal 回调
        SpeechService.shared.stopRecording(
            onPartial: { _ in },
            onFinal: { [weak self] text in
                DispatchQueue.main.async {
                    self?.isRecording = false
                    self?.partialText = ""
                    // 如果没有传入文本，使用最后识别到的文本
                    let finalText = text.isEmpty ? (self?.lastRecognizedText ?? "") : text
                    self?.processAndInput(finalText)
                }
            }
        )
    }

    private func processAndInput(_ text: String) {
        guard !text.isEmpty else {
            statusText = "未识别到内容"
            return
        }
        statusText = "已完成"
        
        // 保存要注入的文本和前台应用，避免闭包捕获问题
        let textToInject = text
        let savedFrontmostApp = frontmostApp
        
        onComplete?(textToInject, savedFrontmostApp)
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
                    .onAppear { pulseScale = 1.3 }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer().frame(height: 12)

            // 波形 - ElevenLabs 暖色调
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { index in
                    WaveBar(index: index, isRecording: viewModel.isRecording)
                }
            }
            .frame(height: 36)
            .opacity(viewModel.isRecording ? 1 : 0.5)

            Spacer().frame(height: 14)

            // 识别文本
            Text(viewModel.statusText)
                .font(.system(size: 15, weight: .regular))
                .tracking(0.16)
                .foregroundColor(viewModel.partialText.isEmpty ? textMuted : textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.2), value: viewModel.statusText)

            Spacer().frame(height: 14)

            // 底部提示
            HStack {
                if !viewModel.isRecording {
                    Text("松开后自动识别")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.14)
                        .foregroundColor(textMuted)
                } else {
                    Text("说完停顿 2 秒自动结束")
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
