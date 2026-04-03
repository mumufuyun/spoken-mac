import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyService: HotKeyService!
    private var recordingWindow: RecordingWindow?

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

        // 否则打开录音浮动窗口
        showRecordingWindow()
    }

    // MARK: - Recording Floating Window

    private func showRecordingWindow() {
        if recordingWindow == nil {
            recordingWindow = RecordingWindow()
        }
        recordingWindow?.show()
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

// MARK: - Recording Floating Window

class RecordingWindow: NSWindow {
    private var isRecording = false
    private var displayLink: CVDisplayLink?

    init() {
        let windowSize = NSSize(width: 300, height: 120)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let windowOrigin = NSPoint(
            x: screenFrame.maxX - windowSize.width - 20,
            y: screenFrame.maxY - windowSize.height - 20
        )

        super.init(
            contentRect: NSRect(origin: windowOrigin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: windowSize))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12

        let contentView = RecordingView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = visualEffect.bounds
        hostingView.autoresizingMask = [.width, .height]

        visualEffect.addSubview(hostingView)
        self.contentView = visualEffect
    }

    func show() {
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    override func close() {
        super.close()
    }
}

struct RecordingView: View {
    @State private var isRecording = false
    @State private var transcript = ""
    @State private var status = "按住说话"

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.gray)
                    .frame(width: 8, height: 8)
                Text("Spoken")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text(status)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}
