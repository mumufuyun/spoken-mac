import AppKit
import Carbon

/// Runs only synthetic Carbon registrations. It never starts Spoken, records audio, or calls a model.
@main
struct HotKeyIntegration {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "--holder" {
            let directory = URL(fileURLWithPath: arguments[2])
            let options = UInt32(arguments[3])!
            let keyCode = UInt32(arguments[4])!
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, UInt32(cmdKey | optionKey | controlKey | shiftKey),
                EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), options, &reference)
            try String(status).write(to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("release").path), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if let reference { UnregisterEventHotKey(reference) }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-hotkey-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        // F20, with all four modifiers: avoid the installed app's real shortcut and common user commands.
        let configuration = HotKeyConfiguration(keyCode: 90, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        let backend = CarbonHotKeyRegistrar()
        try backend.checkSystem(configuration)
        try backend.register(configuration, id: 1)
        var delivered: [(UInt32, Bool)] = []
        backend.onEvent = { delivered.append(($0, $1)) }
        for down in [true, false] {
            var event: EventRef?
            let result = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(down ? kEventHotKeyPressed : kEventHotKeyReleased),
                                     GetCurrentEventTime(), 0, &event)
            guard result == noErr, let event else { throw HotKeyFailure.system("创建测试事件", result) }
            defer { ReleaseEvent(event) }
            var id = EventHotKeyID(signature: CarbonHotKeyRegistrar.signature, id: 1)
            let parameterResult = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
            guard parameterResult == noErr else { throw HotKeyFailure.system("设置测试事件", parameterResult) }
            let deliveryResult = SendEventToEventTarget(event, GetApplicationEventTarget())
            guard deliveryResult == noErr else { throw HotKeyFailure.system("投递测试事件", deliveryResult) }
        }
        guard delivered.count == 2, delivered[0].0 == 1, delivered[0].1, !delivered[1].1 else {
            throw HotKeyFailure.invalid("Carbon event handler did not receive matching press/release")
        }
        passed += 1
        print("PASS: native Carbon handler receives synthetic pressed/released events (not physical keystrokes)")
        backend.unregister(1)
        passed += 1
        print("PASS: unoccupied exclusive registration and cleanup")
        for exclusive in [true, false] {
            let directory = root.appendingPathComponent(exclusive ? "exclusive" : "nonexclusive")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: arguments[0])
            holder.arguments = ["--holder", directory.path, exclusive ? "1" : "0", String(configuration.keyCode)]
            try holder.run()
            defer {
                try? "release".write(to: directory.appendingPathComponent("release"), atomically: true, encoding: .utf8)
                if holder.isRunning { holder.terminate() }
            }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let result = try String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)
            guard result == "0" else { throw HotKeyFailure.system("隔离进程准备", Int32(result) ?? -1) }
            var conflict = false
            do { try backend.register(configuration, id: 2); backend.unregister(2) }
            catch HotKeyFailure.occupied { conflict = true }
            if exclusive {
                guard conflict else { throw HotKeyFailure.invalid("Exclusive owner was not rejected") }
                print("PASS: existing exclusive registration rejected without takeover")
            } else {
                print(conflict ? "PASS: this OS rejects an existing nonexclusive owner" :
                    "BOUNDARY VERIFIED: this OS accepts exclusive registration over a nonexclusive owner; Carbon cannot reliably detect that conflict")
            }
            passed += 1
            try "release".write(to: directory.appendingPathComponent("release"), atomically: true, encoding: .utf8)
            while holder.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            guard !holder.isRunning else { throw HotKeyFailure.invalid("Holder did not exit") }
            try backend.register(configuration, id: 3)
            backend.unregister(3)
            passed += 1
            print("PASS: retry after \(exclusive ? "exclusive" : "nonexclusive") owner exited")
        }
        backend.shutdown()
        print("Carbon integration: \(passed)/6 passed. No input injection, microphone, model, or real preferences used.")
    }
}
