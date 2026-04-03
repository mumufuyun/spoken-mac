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
            closeRecordingPanel()
            return
        }
        showRecordingPanel()
    }

    // MARK: - Recording Panel

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
    @Published var partialText = ""
    @Published var statusText = "点击按钮开始说话"

    var onClose: (() -> Void)?
    var onComplete: ((String) -> Void)?

    func startRecording() {
        isRecording = true
        partialText = ""
        statusText = "正在说话..."

        SpeechService.shared.startRecording(
            onPartial: { [weak self] text in
                DispatchQueue.main.async {
                    self?.partialText = text
                    self?.statusText = text.isEmpty ? "正在说话..." : text
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
        SpeechService.shared.stopRecording()
        isRecording = false
        statusText = "已停止"
    }

    private func processAndInput(_ text: String) {
        guard !text.isEmpty else {
            statusText = "未识别到内容"
            return
        }

        statusText = "优化中..."
        MiniMaxService.shared.optimize(text: text, mode: .text) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let optimized):
                    self?.statusText = "已完成"
                    self?.onComplete?(optimized)
                case .failure:
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
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.blue)
                    .frame(width: 8, height: 8)
                    .shadow(color: viewModel.isRecording ? .red.opacity(0.5) : .clear, radius: 4)

                Text("Spoken")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: { viewModel.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Status / Partial text
            Text(viewModel.partialText.isEmpty ? viewModel.statusText : viewModel.partialText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(viewModel.partialText.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // Record Button
            Button(action: {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13))
                    Text(viewModel.isRecording ? "停止" : "开始说话")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    viewModel.isRecording
                        ? AnyShapeStyle(Color.red)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color(hex: "#4F7DF3"), Color(hex: "#6B5CE7")],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 280, height: 160)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(16)
        )
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

