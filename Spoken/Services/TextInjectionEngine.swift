import AppKit
import ApplicationServices

enum InjectionOutcome: Equatable {
    /// Paste events were sent; the destination application cannot be verified generically.
    case inserted
    case copiedToClipboard
    case permissionRequired
    case clipboardFailed
}

@MainActor
final class TextInjectionEngine {

    private struct ClipboardSnapshot {
        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }
        let items: [Item]
        let wasEmpty: Bool

        static func capture(from pb: NSPasteboard) -> ClipboardSnapshot {
            var items: [Item] = []
            for pbItem in pb.pasteboardItems ?? [] {
                var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
                for type in pbItem.types {
                    if let data = pbItem.data(forType: type) {
                        dataMap[type] = data
                    }
                }
                guard !dataMap.isEmpty else { continue }
                items.append(Item(types: pbItem.types, data: dataMap))
            }
            return ClipboardSnapshot(items: items, wasEmpty: (pb.pasteboardItems ?? []).isEmpty)
        }

        func restore(to pb: NSPasteboard, expectedChangeCount: Int) {
            guard pb.changeCount == expectedChangeCount else { return }
            pb.clearContents()
            guard !wasEmpty else { return }
            let restoredItems: [NSPasteboardItem] = items.map { item in
                let pbItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data[type] {
                        pbItem.setData(data, forType: type)
                    }
                }
                return pbItem
            }
            pb.writeObjects(restoredItems)
        }
    }

    var preserveClipboard = true
    private var pendingClipboardRestore: PendingClipboardRestore?
    private let pasteboard: NSPasteboard
    private let canPaste: () -> Bool
    private let postPaste: () -> Bool
    private let prepareTarget: () -> Void
    private let writeText: (String) -> Bool
    var pendingRestoreID: UUID? { pendingClipboardRestore?.id }

    convenience init() {
        #if SPOKEN_OFFLINE_TESTS
        preconditionFailure("Offline tests must inject text delivery dependencies")
        #else
        self.init(pasteboard: .general, canPaste: { AccessibilityPermissionService.shared.refresh() },
                  postPaste: Self.simulatePasteCGEvent, prepareTarget: {
            if let app = NSWorkspace.shared.frontmostApplication { Self.enableEnhancedAX(for: app) }
            usleep(50_000)
        })
        #endif
    }

    init(pasteboard: NSPasteboard, canPaste: @escaping () -> Bool,
         postPaste: @escaping () -> Bool, prepareTarget: @escaping () -> Void = {},
         writeText: ((String) -> Bool)? = nil) {
        self.pasteboard = pasteboard; self.canPaste = canPaste
        self.postPaste = postPaste; self.prepareTarget = prepareTarget
        self.writeText = writeText ?? { pasteboard.setString($0, forType: .string) }
    }

    private struct PendingClipboardRestore {
        let id = UUID()
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }

        return injectViaClipboard(text)
    }

    func finishClipboardRestore(expectedID: UUID? = nil) {
        guard let pending = pendingClipboardRestore else { return }
        if let expectedID, expectedID != pending.id { return }
        pendingClipboardRestore = nil
        pending.snapshot.restore(to: pasteboard, expectedChangeCount: pending.changeCount)
    }

    private func injectViaClipboard(_ text: String) -> InjectionOutcome {
        pendingClipboardRestore = nil
        let savedClipboard = preserveClipboard ? ClipboardSnapshot.capture(from: pasteboard) : nil
        let pb = pasteboard
        pb.clearContents()
        guard writeText(text) else { return .clipboardFailed }
        let postWriteChangeCount = pb.changeCount
        print("Spoken: [DEBUG] clipboard text prepared, length=\(text.count)")

        usleep(50_000)

        // Use paste simulation for all apps.
        // AX direct value set is unreliable for Electron/Web apps and custom input fields,
        // causing text to become non-interactive static content.
        // Missing authorization must leave the result available for manual paste, without
        // trying a second automation channel or restoring the previous clipboard.
        guard canPaste() else { return .permissionRequired }
        prepareTarget()
        guard canPaste() else { return .permissionRequired }
        let pasteSucceeded = postPaste()

        usleep(150_000)

        // 以粘贴事件是否成功发送作为判断依据
        // frontmostApplication 检查存在 race condition，不作为可靠判断
        let outcome: InjectionOutcome = pasteSucceeded ? .inserted : .copiedToClipboard

        if outcome == .inserted, let savedClipboard {
            pendingClipboardRestore = PendingClipboardRestore(
                snapshot: savedClipboard, changeCount: postWriteChangeCount
            )
        } else {
            pendingClipboardRestore = nil
        }

        return outcome
    }

    // MARK: - AX Helper

    private static func enableEnhancedAX(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        AXUIElementSetAttributeValue(
            window,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
        print("Spoken: [DEBUG] enabled AXEnhancedUserInterface for \(app.localizedName ?? "unknown")")
    }

    // MARK: - CGEvent Paste

    private static func simulatePasteCGEvent() -> Bool {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
