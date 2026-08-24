import AppKit
import ApplicationServices

enum InjectionOutcome {
    case inserted
    case copiedToClipboard
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

        static func capture() -> ClipboardSnapshot {
            let pb = NSPasteboard.general
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

        func restore(expectedChangeCount: Int) {
            let pb = NSPasteboard.general
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

    private struct PendingClipboardRestore {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }

        return injectViaClipboard(text)
    }

    func finishClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        pending.snapshot.restore(expectedChangeCount: pending.changeCount)
    }

    private func injectViaClipboard(_ text: String) -> InjectionOutcome {
        let savedClipboard = preserveClipboard ? ClipboardSnapshot.capture() : nil

        // Enable AX tree for Electron apps (Feishu, VS Code, etc.)
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            enableEnhancedAX(for: frontmostApp)
            usleep(50_000)
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let postWriteChangeCount = pb.changeCount
        print("Spoken: [DEBUG] clipboard text prepared, length=\(text.count)")

        usleep(50_000)

        // Use paste simulation for all apps.
        // AX direct value set is unreliable for Electron/Web apps and custom input fields,
        // causing text to become non-interactive static content.
        // Priority: CGEvent (system-level, most reliable) → osascript (fallback)

        var pasteSucceeded = false
        if AXIsProcessTrusted() {
            simulatePasteCGEvent()
            usleep(100_000)
            pasteSucceeded = true
        } else {
            print("Spoken: [WARN] AX not trusted, falling back to osascript paste")
            pasteSucceeded = simulatePasteViaOsascript()
        }

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

    private func enableEnhancedAX(for app: NSRunningApplication) {
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

    // MARK: - osascript Paste

    private func simulatePasteViaOsascript() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"System Events\" to keystroke \"v\" using command down"
        ]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let exitCode = process.terminationStatus
            if exitCode == 0 {
                print("Spoken: [DEBUG] osascript exit code: 0")
                return true
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown"
                print("Spoken: [DEBUG] osascript exit code: \(exitCode), error: \(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))")
                return false
            }
        } catch {
            print("Spoken: [ERROR] osascript execution failed: \(error)")
            return false
        }
    }

    // MARK: - CGEvent Paste

    private func simulatePasteCGEvent() {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
