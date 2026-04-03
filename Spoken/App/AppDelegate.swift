import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyService: HotKeyService!
    private var recordingPanel: NSPanel?
    private var recordingViewModel = RecordingViewModel()

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
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Spoken")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        let contentView = ContentView()
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 180)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Global HotKey (⌥ + V)

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
        // 如果面板显示了，就关闭
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 如果录音窗口显示了，就关闭
        if recordingPanel?.isVisible == true {
            closeRecordingPanel()
            return
        }
        // 否则打开录音浮动窗口
        showRecordingPanel()
    }

    // MARK: - Recording Panel (⌥V 浮动窗口)

    private func showRecordingPanel() {
        let viewModel = RecordingViewModel()
        let recordingView = RecordingPanelView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: recordingView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hostingController

        // 定位到屏幕右下角
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelSize = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.maxX - panelSize.width - 20,
                y: screenFrame.maxY - panelSize.height - 20
            ))
        }

        viewModel.onClose = { [weak self] in
            self?.closeRecordingPanel()
        }

        viewModel.onComplete = { [weak self] text in
            self?.closeRecordingPanel()
            KeyboardService.shared.typeText(text)
            NotificationService.shared.notifySuccess(text: text)
        }

        self.recordingViewModel = viewModel
        self.recordingPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeRecordingPanel() {
        recordingViewModel.stopRecording()
        recordingPanel?.close()
        recordingPanel = nil
    }

    // MARK: - Permissions

    private func checkPermissions() {
        SpeechService.shared.requestPermissions { micGranted, speechGranted in
            if !micGranted || !speechGranted {
                DispatchQueue.main.async {
                    self.showPermissionAlert()
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
    @Published var transcript = ""
    @Published var statusText = "点击按钮开始说话"

    var onClose: (() -> Void)?
    var onComplete: ((String) -> Void)?

    func startRecording() {
        isRecording = true
        transcript = ""
        statusText = "正在说话..."

        SpeechService.shared.startRecording { [weak self] text in
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.transcript = text
                self?.statusText = "处理中..."
                self?.processAndInput(text)
            }
        }
    }

    func stopRecording() {
        SpeechService.shared.stopRecording()
        isRecording = false
        statusText = "已停止"
    }

    private func processAndInput(_ text: String) {
        guard !text.isEmpty else {
            statusText = "未识别到内容"
            return
        }

        // 走 MiniMax 优化
        MiniMaxService.shared.optimize(text: text, mode: .text) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let optimized):
                    self?.statusText = "已完成"
                    self?.onComplete?(optimized)
                case .failure:
                    // 降级：直接输入原文本
                    self?.statusText = "已完成"
                    self?.onComplete?(text)
                }
            }
        }
    }
}

// MARK: - Recording Panel View

struct RecordingPanelView: View {
    @ObservedObject var viewModel: RecordingViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.blue)
                    .frame(width: 8, height: 8)
                Text("Spoken")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Status
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundColor(.secondary)

            // Record Button
            Button(action: {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }) {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    Text(viewModel.isRecording ? "停止" : "开始说话")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(viewModel.isRecording ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            Spacer()
        }
        .frame(width: 280, height: 160)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(12)
        )
    }
}

// MARK: - Visual Effect View (SwiftUI wrapper for macOS NSVisualEffectView)

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
