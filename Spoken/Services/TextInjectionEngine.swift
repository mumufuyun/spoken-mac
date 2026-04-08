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
        usleep(50_000)
        pending.snapshot.restore(expectedChangeCount: pending.changeCount)
    }

    private func injectViaClipboard(_ text: String) -> InjectionOutcome {
        let savedClipboard = preserveClipboard ? ClipboardSnapshot.capture() : nil
        let hasFrontmostApp = NSWorkspace.shared.frontmostApplication != nil

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let postWriteChangeCount = pb.changeCount

        usleep(50_000)

        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else {
            return .copiedToClipboard
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        usleep(100)

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
}
