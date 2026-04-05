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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
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

        viewModel.onComplete = { [weak self] text in
            self?.closeRecordingPanel()
            // 等待窗口关闭动画完成后再输入
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                KeyboardService.shared.typeText(text)
            }
            NotificationService.shared.notifySuccess(text: text)
        }

        self.recordingViewModel = viewModel
        self.recordingPanel = panel
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            viewModel.startRecording()
        }
    }

    private func closeRecordingPanel() {
        recordingViewModel.stopRecording()
        recordingPanel?.orderOut(nil)
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
    @Published var statusText = "正在聆听..."

    var onClose: (() -> Void)?
    var onComplete: ((String) -> Void)?

    func startRecording() {
        isRecording = true
        partialText = ""
        statusText = "正在聆听..."

        SpeechService.shared.startRecording(
            onPartial: { [weak self] text in
                print("Spoken: [DEBUG] onPartial called with: '\(text)'")
                DispatchQueue.main.async {
                    self?.partialText = text
                    if !text.isEmpty {
                        self?.statusText = text
                    }
                    print("Spoken: [DEBUG] viewModel updated: statusText='\(self?.statusText ?? "?")'")
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
        statusText = "已完成"
        onComplete?(text)
    }
}

// MARK: - Recording Panel View

struct RecordingPanelView: View {
    @ObservedObject var viewModel: RecordingViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 16)

            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    WaveBar(index: index, isRecording: viewModel.isRecording)
                }
            }
            .frame(height: 32)
            .opacity(viewModel.isRecording ? 1 : 0.5)

            Spacer().frame(height: 12)

            Text(viewModel.statusText)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(viewModel.partialText.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)

            Spacer().frame(height: 16)

            HStack {
                Text("对着说话，自动输入")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { viewModel.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(width: 420, height: 160)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(20)
        )
    }
}

// MARK: - 波形动画条

struct WaveBar: View {
    let index: Int
    let isRecording: Bool

    @State private var animOffset: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [Color(hex: "#4F7DF3"), Color(hex: "#6B5CE7")],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: 4, height: isRecording ? animOffset : 6)
            .animation(
                Animation.easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.1),
                value: animOffset
            )
            .onAppear {
                if isRecording {
                    animOffset = CGFloat.random(in: 12...28)
                }
            }
            .onChange(of: isRecording) { _, newValue in
                if newValue {
                    animOffset = CGFloat.random(in: 12...28)
                } else {
                    animOffset = 6
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
