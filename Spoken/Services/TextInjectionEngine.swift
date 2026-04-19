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

        // Detect IDEs upfront - they don't support AX value setting reliably
        let isIDE: Bool
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontmostApp.bundleIdentifier {
            isIDE = bundleID.contains("vscode") || bundleID.contains("code") ||
                    bundleID.contains("trae") || bundleID.contains("cursor") ||
                    bundleID.contains("jetbrains") || bundleID.contains("intellij") ||
                    bundleID.contains("com.microsoft.VSCode")
            if isIDE {
                print("Spoken: [DEBUG] Detected IDE (\(bundleID)), skipping AX direct set")
            }
        } else {
            isIDE = false
        }

        // Try paste methods in order: AX → osascript → CGEvent
        // Each method is tried only if the previous one failed
        var pasteSucceeded = false
        
        if !isIDE {
            pasteSucceeded = tryAXSetFocusedTextValue(text)
            if pasteSucceeded {
                print("Spoken: [DEBUG] AX direct value set succeeded")
            }
        }

        if !pasteSucceeded {
            print("Spoken: [DEBUG] AX skipped/failed, trying osascript paste")
            pasteSucceeded = simulatePasteViaOsascript()
            if pasteSucceeded {
                print("Spoken: [DEBUG] osascript paste succeeded")
            }
        }

        if !pasteSucceeded {
            print("Spoken: [DEBUG] osascript failed, trying CGEvent paste")
            let axTrusted = AXIsProcessTrusted()
            if axTrusted {
                simulatePasteCGEvent()
                usleep(100_000)
                pasteSucceeded = true
            }
        }

        usleep(100_000)

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

    // MARK: - AX Direct Value Set (Most Reliable)

    private func tryAXSetFocusedTextValue(_ text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)

        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedObj) == .success,
              let focusedElement = focusedObj as! AXUIElement? else {
            print("Spoken: [DEBUG] AX: no focused element")
            return false
        }

        let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            return true
        }
        print("Spoken: [DEBUG] AX setValue failed: \(setResult.rawValue)")
        return false
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
