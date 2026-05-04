import AppKit
import ApplicationServices

enum InjectionOutcome {
    case inserted
    case copiedToClipboard
}

final class TextInjectionEngine: @unchecked Sendable {

    private struct ClipboardSnapshot {
        static let safeTypes: [NSPasteboard.PasteboardType] = [
            .string,
            .URL,
            .html,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-plain-text"),
            NSPasteboard.PasteboardType("public.url"),
        ]

        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }
        let items: [Item]
        let changeCount: Int

        static func capture() -> ClipboardSnapshot {
            let pb = NSPasteboard.general
            let changeCount = pb.changeCount
            let safeSet = Set(safeTypes.map(\.rawValue))
            var items: [Item] = []
            for pbItem in pb.pasteboardItems ?? [] {
                let textTypes = pbItem.types.filter { safeSet.contains($0.rawValue) }
                guard !textTypes.isEmpty else { continue }
                var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
                for type in textTypes {
                    if let data = pbItem.data(forType: type) {
                        dataMap[type] = data
                    }
                }
                items.append(Item(types: textTypes, data: dataMap))
            }
            return ClipboardSnapshot(items: items, changeCount: changeCount)
        }

        func restore(expectedChangeCount: Int) {
            let pb = NSPasteboard.general
            guard !items.isEmpty else { return }
            guard pb.changeCount == expectedChangeCount else { return }
            pb.clearContents()
            for item in items {
                let pbItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data[type] {
                        pbItem.setData(data, forType: type)
                    }
                }
                pb.writeObjects([pbItem])
            }
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
        usleep(300_000)
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
        print("Spoken: [DEBUG] clipboard written: \(pb.string(forType: .string)?.prefix(30) ?? "nil")")

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

        let hasFrontmostApp = NSWorkspace.shared.frontmostApplication != nil
        let outcome: InjectionOutcome = hasFrontmostApp ? .inserted : .copiedToClipboard

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
