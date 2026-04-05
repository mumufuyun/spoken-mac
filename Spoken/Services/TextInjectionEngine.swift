import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 文本注入引擎 - 基于 type4me 实现
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

    // MARK: - Public

    var preserveClipboard = true

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

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Private

    private struct PendingClipboardRestore {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    private var pendingClipboardRestore: PendingClipboardRestore?

    private func injectViaClipboard(_ text: String) -> InjectionOutcome {
        let savedClipboard = preserveClipboard ? ClipboardSnapshot.capture() : nil

        let hasFrontmostApp = NSWorkspace.shared.frontmostApplication != nil

        // 写剪贴板
        copyToClipboard(text)
        let postWriteChangeCount = NSPasteboard.general.changeCount

        // type4me 精确时序：50µs 后发 paste，立即返回
        // 不激活 app，不延迟
        usleep(50_000)
        simulatePaste()
        usleep(100_000)

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

    private func simulatePaste() {
        // 关键：source 传 nil，macOS 自动选择正确的事件源
        let vKeyCode: CGKeyCode = 9 // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Accessibility API 直接设值（备选，不依赖焦点路由）

    /// 直接通过 Accessibility API 设置焦点文本框的值
    /// 如果 CGEvent 路由失败，尝试这个方法
    func injectViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard status == .success, let element = focusedElement else {
            print("TextInjectionEngine: AX - no focused element")
            return false
        }

        let axElement = unsafeDowncast(element, to: AXUIElement.self)

        // 检查是否可以设置 AXValue
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable)

        if settable.boolValue {
            AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, text as CFTypeRef)
            print("TextInjectionEngine: AX - set AXValue directly")
            return true
        }

        // 如果是文本选择区域，尝试插入
        var selectedRange: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if rangeStatus == .success {
            AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            print("TextInjectionEngine: AX - set AXSelectedText directly")
            return true
        }

        print("TextInjectionEngine: AX - could not set value")
        return false
    }
}
