import Foundation
import SwiftUI
import AVFoundation
import Carbon

private struct TestFailure: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

private final class MockProtocol: URLProtocol {
    struct Reply {
        var json: [String: Any]
        var status = 200
        var delay: TimeInterval = 0
        var error: URLError?
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var received: [URLRequest] = []
    private var work: DispatchWorkItem?

    static func reset(_ plans: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = plans
        received = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession may move httpBody into a stream before invoking URLProtocol.
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.received.append(captured)
        let reply = Self.replies.isEmpty
            ? Reply(json: [:], error: URLError(.unsupportedURL))
            : Self.replies.removeFirst()
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.json))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
    }

    override func stopLoading() { work?.cancel() }
}

// No CFPreferences domains or application settings are read or written.
private final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
        super.init(suiteName: "Spoken.OfflineTests.\(UUID().uuidString)")!
    }

    override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
}

private final class Fixture {
    let defaults: MemoryDefaults
    let session: URLSession
    var messages: [String] = []
    private let lock = NSLock()

    init(model: String = "qwen3.8-flash", url: String = "https://dashscope.aliyuncs.com/compatible-mode/v1") {
        defaults = MemoryDefaults(["llm_provider": "custom", "llm_custom_base_url": url, "llm_custom_model": model,
                                   MiniMaxService.thinkingEnabledKey: true, PersonalContextStore.enabledKey: false])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    func service(timeout: TimeInterval = 2) -> MiniMaxService {
        MiniMaxService(defaults: defaults, session: session, apiKeyProvider: { "offline-test-key" },
                       timeoutOverride: timeout, log: { [weak self] message in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.messages.append(message)
        })
    }

    deinit {
        session.invalidateAndCancel()
    }
}

private final class MemoryKeys: ConnectionKeyStore {
    var values: [String: String] = [:]
    var legacy: String?
    var failRead = false
    var failWrite = false
    var reads = 0
    var legacyRequiresInteraction = false
    var noninteractiveLegacyReads = 0
    func readLegacyCredentialWithoutUI() throws -> String? {
        noninteractiveLegacyReads += 1
        if legacyRequiresInteraction { throw TestFailure(description: "Interaction required") }
        return try readLegacyCredential()
    }
    func readCredential(_ id: String) throws -> String? {
        reads += 1
        if failRead { throw TestFailure(description: "Keychain locked") }
        return values[id]
    }
    func writeCredential(_ key: String, id: String) throws {
        if failWrite { throw TestFailure(description: "Keychain save failed") }
        values[id] = key
    }
    func removeCredential(_ id: String) throws { values.removeValue(forKey: id) }
    func readLegacyCredential() throws -> String? {
        reads += 1
        if failRead { throw TestFailure(description: "Keychain locked") }
        return legacy
    }
}

private final class ConfigurationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-config-tests-" + UUID().uuidString)
    let defaults: MemoryDefaults
    let keys = MemoryKeys()
    var failingFiles = Set<String>()
    var permissionState: TextInputPermission = .ready
    var settingsOpenSucceeds = true
    var settingsOpenCount = 0
    @MainActor lazy var accessibility = AccessibilityPermissionService(defaults: defaults,
        readPermission: { [unowned self] in permissionState },
        openSettings: { [unowned self] in settingsOpenCount += 1; return settingsOpenSucceeds })
    @MainActor lazy var hotkeyRegistrar = FakeHotKeyRegistrar()
    @MainActor lazy var hotkeys: HotKeyService = {
        let service = HotKeyService(file: file("hotkey-v1"), registrar: hotkeyRegistrar, defaults: defaults)
        service.registerAll()
        return service
    }()
    lazy var modes = ModeStore(defaults: defaults, file: file("modes"), backupFile: file("backup"))
    lazy var connections = ModelConnectionStore(defaults: defaults, file: file("connections"), keys: keys)
    init(_ values: [String: Any] = [:]) { defaults = MemoryDefaults(values) }
    lazy var speechConnections = SpeechConnectionStore(file: file("speech-connections"), keys: keys, defaults: defaults)
    var speechSettings: SpeechSettingsDependencies {
        SpeechSettingsDependencies(defaults: defaults, store: speechConnections,
            refreshConnection: { _ in }, isBusy: { false },
            metrics: { ASRMetricsSnapshot(sessions: 0, connected: 0, successes: 0, failures: 0, reconnects: 0, fallbacks: 0) }, latency: { [:] })
    }
    func file(_ name: String) -> ConfigurationFile {
        let normal = ConfigurationFile(url: root.appendingPathComponent(name + ".json"))
        return ConfigurationFile(url: normal.url, write: { [weak self] data, url in
            if self?.failingFiles.contains(name) == true { throw TestFailure(description: "Disk write failed") }
            try normal.write(data, url)
        })
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@main
private struct AIProcessingRegression {
    static let input = "原始口述，仅用于本地测试"

    static func answer(_ text: String, reason: String = "stop") -> [String: Any] {
        ["choices": [["message": ["content": text], "finish_reason": reason]]]
    }

    @MainActor
    static func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    static func process(_ service: MiniMaxService, text: String = input,
                        mode: SpokenMode = .aiInstruction, language: TranslateLanguage = .original) throws -> Result<String, Error> {
        var result: Result<String, Error>?
        service.process(text: text, mode: mode, translateLang: language) { result = $0 }
        spin(4, until: { result != nil })
        guard let result else { throw TestFailure(description: "Completion did not arrive") }
        return result
    }

    static func body(_ index: Int = 0) throws -> [String: Any] {
        let requests = MockProtocol.requests
        try check(requests.indices.contains(index), "Expected captured request")
        return try JSONSerialization.jsonObject(with: requests[index].httpBody!) as! [String: Any]
    }

    static func expectFailure(_ result: Result<String, Error>, code: String) throws {
        guard case .failure(let error) = result else { throw TestFailure(description: "Expected failure: \(code)") }
        try check((error as? MiniMaxError)?.outcomeCode == code, "Wrong failure: \(error)")
    }

    @MainActor
    static func main() {
        if Bundle.main.bundleIdentifier == "com.spoken.offline-smoke" {
            do { try launchInteractiveSmoke() }
            catch { print("FAIL: Interactive smoke setup: \(error)"); exit(1) }
            return
        }
        let tests: [(String, () throws -> Void)] = [
            ("Updater: installation waits for active speech and resumes once", {
                var busy = true
                var installs = 0
                let updates = AppUpdateService(isBusy: { busy })
                try check(updates.postponeInstallationIfBusy { installs += 1 }, "Active speech did not defer installation")
                updates.activityDidChange()
                try check(installs == 0 && updates.isWaitingForIdle && !updates.isInstalling, "Installed while speech is active")
                busy = false
                updates.activityDidChange()
                updates.activityDidChange()
                try check(installs == 1 && !updates.isWaitingForIdle && updates.isInstalling, "Install was not resumed exactly once")
            }),
            ("Updater: idle installation locks out new recordings", {
                let updates = AppUpdateService()
                var calls = 0
                try check(!updates.postponeInstallationIfBusy { calls += 1 }, "Idle installation was postponed")
                try check(updates.isInstalling && calls == 0, "Sparkle must own immediate installation")
            }),
            ("Updater: canceled update cannot later resume installation", {
                var busy = true
                var installs = 0
                let updates = AppUpdateService(isBusy: { busy })
                _ = updates.postponeInstallationIfBusy { installs += 1 }
                updates.finishUpdateSession()
                busy = false
                updates.activityDidChange()
                try check(installs == 0 && !updates.isInstalling && !updates.isWaitingForIdle, "Canceled install resumed")
            }),
            ("Qwen ignores legacy thinking=true and sends false", {
                MockProtocol.reset([.init(json: answer("整理后的正文"))])
                let f = Fixture()
                let result = try process(f.service())
                try check(try result.get() == "整理后的正文", "Normal response missing")
                try check(try body()["enable_thinking"] as? Bool == false, "Qwen must explicitly disable thinking")
                try check(f.messages.contains { $0.contains("outcome=success") }, "Success not recorded")
                try check(!f.messages.joined().contains(input), "Logs contain transcript")
                try check(!f.messages.joined().contains("offline-test-key"), "Logs contain key")
            }),
            ("Qwen explicit opt-in sends true", {
                MockProtocol.reset([.init(json: answer("正文"))])
                let f = Fixture()
                f.set(MiniMaxService.qwenThinkingEnabledKey, true)
                _ = try process(f.service())
                try check(try body()["enable_thinking"] as? Bool == true, "Qwen opt-in lost")
            }),
            ("DeepSeek retains its existing setting", {
                MockProtocol.reset([.init(json: answer("正文"))])
                let f = Fixture(model: "deepseek-v4-flash-0731")
                _ = try process(f.service())
                try check(try body()["enable_thinking"] as? Bool == true, "DeepSeek preference changed")
            }),
            ("Unsupported providers receive no extra parameter", {
                MockProtocol.reset([.init(json: answer("正文"))])
                let f = Fixture(model: "MiniMax-M2.5", url: "https://api.minimax.chat/v1")
                _ = try process(f.service())
                try check(try body()["enable_thinking"] == nil, "Unsupported parameter leaked")
                try check(!MiniMaxService.supportsThinkingToggle(model: "qwen3.8-flash", baseURL: "https://dashscope.aliyuncs.com.example.org/v1"), "Host substring accepted")
            }),
            ("Long text deadline grows and stays bounded", {
                try check(MiniMaxService.aiTimeout(forInputLength: 100, thinkingEnabled: false) == 20, "Short timeout changed")
                try check(MiniMaxService.aiTimeout(forInputLength: 2000, thinkingEnabled: false) == 35, "Long text still limited to 20s")
                try check(MiniMaxService.aiTimeout(forInputLength: 20000, thinkingEnabled: false) == 60, "Unbounded timeout")
                try check(MiniMaxService.aiTimeout(forInputLength: 100, thinkingEnabled: true) == 45, "Thinking budget mismatch")
            }),
            ("Deadline reports failure exactly once; no silent success", {
                MockProtocol.reset([.init(json: answer("迟到的正文"), delay: 0.3)])
                let f = Fixture()
                let service = f.service(timeout: 0.06)
                var results: [Result<String, Error>] = []
                service.process(text: input, mode: .aiInstruction, translateLang: .original) { results.append($0) }
                spin(0.45)
                try check(results.count == 1, "Deadline callback count wrong")
                try expectFailure(results[0], code: "timeout")
                try check(f.messages.contains { $0.contains("outcome=timeout") }, "Timeout not recorded")
            }),
            ("Empty or reasoning-only output is a failure", {
                for text in ["  \n", "<think>internal reasoning</think>"] {
                    MockProtocol.reset([.init(json: answer(text))])
                    let f = Fixture()
                    try expectFailure(try process(f.service()), code: "empty_output")
                }
                MockProtocol.reset([.init(json: ["choices": [["message": ["content": NSNull(), "reasoning_content": "reasoning"], "finish_reason": "stop"]]])])
                let f = Fixture()
                try expectFailure(try process(f.service()), code: "empty_output")
            }),
            ("Truncated output never becomes successful partial text", {
                MockProtocol.reset([.init(json: answer("只完成了一半", reason: "length"))])
                let f = Fixture()
                try expectFailure(try process(f.service()), code: "incomplete_output")
            }),
            ("Non-2xx response is rejected even with content", {
                MockProtocol.reset([.init(json: answer("错误正文"), status: 503)])
                let f = Fixture()
                try expectFailure(try process(f.service()), code: "api_error")
            }),
            ("Existing native response formats remain usable", {
                for json: [String: Any] in [
                    ["choices": [["messages": [["text": "原生正文"]]]]], ["output": "原生正文"]
                ] {
                    MockProtocol.reset([.init(json: json)])
                    let f = Fixture()
                    try check(try process(f.service()).get() == "原生正文", "Native compatibility failed")
                }
            }),
            ("Cancellation suppresses completion and retries", {
                MockProtocol.reset([.init(json: answer("迟到的正文"), delay: 0.2)])
                let f = Fixture()
                let service = f.service(timeout: 0.4)
                var completions = 0
                service.process(text: input, mode: .aiInstruction, translateLang: .original) { _ in completions += 1 }
                spin(0.04)
                service.cancelCurrentTask()
                spin(0.5)
                try check(completions == 0 && MockProtocol.requests.count == 1, "Cancelled request escaped")
            }),
            ("New request supersedes old without stale completion", {
                MockProtocol.reset([.init(json: answer("旧正文"), delay: 0.2), .init(json: answer("新正文"))])
                let f = Fixture()
                let service = f.service()
                var oldCount = 0
                service.process(text: input, mode: .aiInstruction, translateLang: .original) { _ in oldCount += 1 }
                spin(0.04)
                try check(try process(service).get() == "新正文", "New request missing")
                spin(0.25)
                try check(oldCount == 0, "Superseded request completed")
            }),
            ("Retry uses original configuration and deadline", {
                MockProtocol.reset([.init(json: [:], error: URLError(.networkConnectionLost)), .init(json: answer("重试正文"))])
                let f = Fixture()
                let service = f.service()
                var result: Result<String, Error>?
                service.process(text: input, mode: .aiInstruction, translateLang: .original) { result = $0 }
                spin(0.08)
                f.set("llm_custom_model", "different-model")
                spin(2, until: { result != nil })
                try check(try result?.get() == "重试正文", "Retry failed")
                try check(try body(1)["model"] as? String == "qwen3.8-flash", "Retry changed models")
                MockProtocol.reset([.init(json: [:], error: URLError(.networkConnectionLost))])
                try expectFailure(try process(f.service(timeout: 0.08)), code: "timeout")
                spin(1.1)
                try check(MockProtocol.requests.count == 1, "Retry started after deadline")
            }),
            ("Custom prompt and translation survive request changes", {
                MockProtocol.reset([.init(json: answer("result"))])
                let f = Fixture()
                f.set(SpokenMode.aiInstruction.promptUserDefaultsKey, "CUSTOM {text}")
                _ = try process(f.service(), language: .english)
                let messages = try body()["messages"] as! [[String: String]]
                let prompt = messages.first { $0["role"] == "user" }!["content"]!
                try check(prompt.contains("CUSTOM \(input)"), "Custom prompt ignored")
                try check(prompt.contains("英文"), "Translation lost")
            }),
            ("Raw transcript requests AI light cleanup", {
                MockProtocol.reset([.init(json: answer("整理后正文"))])
                let f = Fixture()
                try check(try process(f.service(), mode: .rawTranscript).get() == "整理后正文", "Raw cleanup output wrong")
                let messages = try body()["messages"] as! [[String: String]]
                let prompt = messages.first { $0["role"] == "user" }!["content"]!
                let expected = AIProcessingService.defaultPrompt(for: .rawTranscript).replacingOccurrences(of: "{text}", with: input)
                try check(prompt.contains(expected), "Raw cleanup rules or text missing")
            }),
            ("ViewModel retains original and exposes failure notice", {
                let vm = RecordingViewModel()
                var outputs: [String] = []
                vm.onComplete = { text, _ in outputs.append(text) }
                for error in [MiniMaxError.timeout, .emptyOutput, .incompleteOutput, .parseError] {
                    vm.finishAIProcessing(.failure(error), originalText: input)
                    try check(outputs.last == input, "Original lost")
                    try check(vm.fallbackNotice == MiniMaxError.fallbackNotice(for: error), "Notice missing")
                }
                vm.finishAIProcessing(.success("   "), originalText: input)
                try check(outputs.last == input && vm.fallbackNotice != nil, "Empty success bypassed notice")
                vm.finishAIProcessing(.success("有效正文"), originalText: input)
                try check(outputs.last == "有效正文" && vm.fallbackNotice == nil, "Stale notice on success")
                vm.isCancelled = true
                let count = outputs.count
                vm.finishAIProcessing(.success("迟到正文"), originalText: input)
                try check(outputs.count == count, "Cancelled ViewModel emitted text")
            })
        ] + configurationTests() + reviewTests() + outputGuardTests() + hotkeyTests() + accessibilityTests() + speechProviderTests() + recoveryTests()
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Offline AI checks: \(tests.count - failures)/\(tests.count) passed. No external model requests.")
        if let index = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.count > index + 1 {
            do { try renderInterfaceSamples(at: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) }
            catch { failures += 1; print("FAIL: Interface rendering: \(error)") }
        }
        exit(failures == 0 ? 0 : 1)
    }
}

private extension AIProcessingRegression {
    static func mustThrow(_ action: () throws -> Void) throws {
        var caught = false
        do { try action() } catch { caught = true }
        try check(caught, "Expected operation to fail")
    }

    @MainActor
    static func configurationTests() -> [(String, () throws -> Void)] {
        [
            ("Custom modes persist, enforce creation cap and preserve stable IDs", {
                let f = ConfigurationFixture()
                try check(f.modes.loadError == nil && f.modes.modes.count == 7, "Initial mode migration failed")
                let first = f.modes.draft()
                try f.modes.save(first, baseRules: f.modes.configuration.baseRules)
                try f.modes.select(first.id)
                var renamed = first; renamed.name = "我的问答"
                try f.modes.save(renamed, baseRules: f.modes.configuration.baseRules)
                try check(f.modes.selected.id == first.id && f.modes.selected.name == renamed.name, "Rename changed identity")
                for _ in 0..<2 { try f.modes.save(f.modes.draft(), baseRules: f.modes.configuration.baseRules) }
                try mustThrow { try f.modes.save(f.modes.draft(), baseRules: f.modes.configuration.baseRules) }
                let reloaded = ModeStore(defaults: f.defaults, file: f.file("modes"), backupFile: f.file("backup"))
                try check(reloaded.customModes.count == 3 && reloaded.selected.id == first.id, "Restart lost custom modes")
                try reloaded.delete(first.id)
                try check(reloaded.selected.builtin == .rawTranscript, "Deleted selected mode did not fall back to raw")
                try reloaded.save(reloaded.draft(), baseRules: reloaded.configuration.baseRules)
                try mustThrow { try reloaded.delete(WritingScene.aiInstruction.storageID) }
            }),
            ("Mode validation rejects blank names, duplicate names and empty rules", {
                let f = ConfigurationFixture()
                var draft = f.modes.draft(); draft.name = "   "
                try mustThrow { try f.modes.save(draft, baseRules: "base") }
                draft.name = "AI 指令"
                try mustThrow { try f.modes.save(draft, baseRules: "base") }
                draft.name = "新模式"; draft.sceneRules = " \n"
                try mustThrow { try f.modes.save(draft, baseRules: "base") }
                draft.sceneRules = "回答问题"
                try mustThrow { try f.modes.save(draft, baseRules: " ") }
                try check(f.modes.customModes.isEmpty, "Invalid drafts were persisted")
            }),
            ("Prompt migration backs up exact overrides then enables new defaults once", {
                let old = "我的旧 Prompt\n{text}\n保留原样"
                let f = ConfigurationFixture([WritingScene.aiInstruction.promptUserDefaultsKey: old,
                    WritingScene.defaultsKey: "AI 指令"])
                try check(f.modes.selected.builtin == .aiInstruction, "Legacy selection lost")
                let backup = try f.file("backup").read(LegacyPromptBackup.self)!
                try check(backup.overrides[WritingScene.aiInstruction.storageID] == old, "Backup not exact")
                try check(!f.modes.selected.sceneRules.contains("我的旧 Prompt"), "Legacy override still active")
                try check(try f.modes.legacyPrompts().contains(old), "Backup UI source unavailable")
                try f.modes.save(f.modes.selected, baseRules: "我新保存的基础规则")
                f.defaults.set("后来修改", forKey: WritingScene.aiInstruction.promptUserDefaultsKey)
                f.modes.reload()
                try check(f.modes.configuration.baseRules == "我新保存的基础规则", "Migration ran twice")
                try check(try f.file("backup").read(LegacyPromptBackup.self)!.overrides[WritingScene.aiInstruction.storageID] == old, "Backup overwritten")
                let attributes = try FileManager.default.attributesOfItem(atPath: f.file("backup").url.path)
                try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Backup permissions too broad")
            }),
            ("Failed backup or migration write preserves old state and can retry", {
                let f = ConfigurationFixture([WritingScene.workMessage.promptUserDefaultsKey: "旧规则", WritingScene.defaultsKey: "work_message"])
                f.failingFiles.insert("backup")
                try check(f.modes.loadError != nil, "Backup failure hidden")
                try check(f.modes.selected.builtin == .workMessage, "Failed migration silently switched to raw")
                try check(!FileManager.default.fileExists(atPath: f.file("modes").url.path), "Published configuration before backup")
                try check(f.defaults.string(forKey: WritingScene.workMessage.promptUserDefaultsKey) == "旧规则", "Old state overwritten")
                f.failingFiles = ["modes"]; f.modes.reload()
                try check(f.modes.loadError != nil && FileManager.default.fileExists(atPath: f.file("backup").url.path), "Mid-migration failure not preserved")
                f.defaults.set("不应覆盖备份", forKey: WritingScene.workMessage.promptUserDefaultsKey)
                f.failingFiles = []; f.modes.reload()
                try check(f.modes.loadError == nil, "Migration retry failed")
                try check(try f.file("backup").read(LegacyPromptBackup.self)!.overrides[WritingScene.workMessage.storageID] == "旧规则", "Retry replaced original backup")
            }),
            ("Mode save failures and future configuration versions never overwrite data", {
                let f = ConfigurationFixture()
                let original = f.modes.configuration
                f.failingFiles.insert("modes")
                try mustThrow { try f.modes.save(f.modes.draft(), baseRules: "changed") }
                try check(f.modes.configuration == original, "Failed write changed memory state")
                f.failingFiles = []
                var future = original; future.version = 99
                try f.file("modes").save(future)
                f.modes.reload()
                try check(f.modes.loadError != nil, "Future version silently accepted")
                try mustThrow { try f.modes.select(WritingScene.casualChat.storageID) }
                try check(try f.file("modes").read(ModeConfiguration.self)!.version == 99, "Future version overwritten")
            }),
            ("Built-in editing rules remain separate from user-defined answering modes", {
                for scene in WritingScene.allCases {
                    let rules = PromptComposer.defaultSceneRules(for: scene)
                    try check(!rules.contains("{text}"), "Placeholder leaked into new scene")
                    try check(!rules.contains(AIProcessingService.sceneSafetyRules), "Legacy base duplicated")
                    try check(rules.contains("只整理原话"), "Built-in became an answering mode")
                }
                let mode = ModeDefinition(id: UUID().uuidString, name: "问答", sceneRules: "直接回答问题")
                let result = PromptComposer.systemPrompt(mode: mode, baseRules: "共同规则", language: .japanese, personalContext: "称呼：不该注入的名字\n领域：测试")
                try check(result.contains("直接回答问题") && result.contains("领域：测试"), "Custom mode lost user rules or personal context")
                try check(!result.contains("共同规则") && !result.contains("日文") && !result.contains("不该注入的名字"), "Custom mode picked up base rules, language or unfiltered context")
                try check(result.hasSuffix(PromptComposer.outputContract), "Custom mode missed the output contract")
                let builtIn = PromptComposer.systemPrompt(mode: .preset(.workMessage), baseRules: "共同规则", language: .japanese, personalContext: "称呼：不该注入的名字\n领域：测试")
                try check(builtIn.contains("共同规则") && builtIn.contains("日文") && builtIn.hasSuffix(PromptComposer.outputContract), "Built-in composition lost a section")
                try check(!builtIn.contains("不该注入的名字") && builtIn.contains("领域：测试"), "Personal context filtering regressed")
            }),
            ("Legacy v2 constants match the pre-iteration defaults", {
                try check(LegacyPromptsV2.sceneRules(for: .aiInstruction).contains("优先明确任务目标"), "Legacy AI rules drifted")
                try check(LegacyPromptsV2.sceneRules(for: .aiInstruction).hasSuffix("不补写事实、观点或行动项。"), "Legacy suffix wrong")
                try check(LegacyPromptsV2.baseRules.contains("中英混合识别") && LegacyPromptsV2.baseRules != PromptComposer.defaultBaseRules, "Legacy base rules drifted")
            }),
            ("Legacy v3 constants match the pre-short-input-fix defaults", {
                try check(LegacyPromptsV3.baseRules.contains("不整段照抄口语原文充数") && !LegacyPromptsV3.baseRules.contains("短输入"), "Legacy v3 base rules drifted")
                try check(LegacyPromptsV3.sceneRules(for: .aiInstruction).contains("把指令整理到可直接执行的程度"), "Legacy v3 AI rules drifted")
                try check(LegacyPromptsV3.sceneRules(for: .meetingNotes).contains("也用清晰要点整理，不直接照抄"), "Legacy v3 meeting rules drifted")
                try check(LegacyPromptsV3.sceneRules(for: .contentShare).contains("不自行补写总结、号召或展望"), "Legacy v3 share rules drifted")
                try check(LegacyPromptsV3.sceneRules(for: .casualChat) != PromptComposer.defaultSceneRules(for: .casualChat), "v6 iteration must refresh casual chat rules")
                try check(LegacyPromptsV3.baseRules != PromptComposer.defaultBaseRules
                    && LegacyPromptsV3.sceneRules(for: .aiInstruction) != PromptComposer.defaultSceneRules(for: .aiInstruction), "v3 and v4 defaults must differ where fixed")
            }),
            ("v3 configuration refreshes untouched built-in rules and preserves user edits", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 3
                legacy.baseRules = LegacyPromptsV3.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV3.sceneRules(for: scene), builtin: scene)
                }
                let customText = "我自己改过的指令规则"
                legacy.modes[legacy.modes.firstIndex { $0.builtin == .aiInstruction }!].sceneRules = customText
                legacy.selectedID = WritingScene.meetingNotes.storageID
                try f.file("modes").save(legacy)
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v3 migration did not complete")
                try check(f.modes.configuration.baseRules == PromptComposer.defaultBaseRules, "Base rules not refreshed")
                try check(f.modes.selected.builtin == .meetingNotes, "Selection lost")
                try check(f.modes.modes.first { $0.builtin == .contentShare }!.sceneRules == PromptComposer.defaultSceneRules(for: .contentShare), "Untouched v3 rules not refreshed")
                try check(f.modes.modes.first { $0.builtin == .aiInstruction }!.sceneRules == customText, "User edit overwritten")
                try check(try f.file("modes").read(ModeConfiguration.self)!.version == ModeConfiguration.currentVersion, "v3 migration not persisted")
            }),
            ("Failed v3 migration leaves the original file intact for retry", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 3
                legacy.baseRules = LegacyPromptsV3.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV3.sceneRules(for: scene), builtin: scene)
                }
                try f.file("modes").save(legacy)
                f.failingFiles.insert("modes")
                try check(f.modes.loadError != nil, "v3 migration failure hidden")
                let persisted = try f.file("modes").read(ModeConfiguration.self)!
                try check(persisted.version == 3 && persisted.baseRules == LegacyPromptsV3.baseRules, "Failed v3 migration overwrote file")
                f.failingFiles = []
                f.modes.reload()
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v3 retry failed")
            }),
            ("v2 configuration refreshes untouched built-in rules and preserves user edits", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 2
                legacy.baseRules = LegacyPromptsV2.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV2.sceneRules(for: scene), builtin: scene)
                }
                let customText = "我自己改过的指令规则"
                legacy.modes[legacy.modes.firstIndex { $0.builtin == .aiInstruction }!].sceneRules = customText
                legacy.selectedID = WritingScene.workMessage.storageID
                try f.file("modes").save(legacy)
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "Migration did not complete")
                try check(f.modes.configuration.baseRules == PromptComposer.defaultBaseRules, "Base rules not refreshed")
                try check(f.modes.selected.builtin == .workMessage, "Selection lost")
                try check(f.modes.modes.first { $0.builtin == .casualChat }!.sceneRules == PromptComposer.defaultSceneRules(for: .casualChat), "Untouched rules not refreshed")
                try check(f.modes.modes.first { $0.builtin == .aiInstruction }!.sceneRules == customText, "User edit overwritten")
                try check(try f.file("modes").read(ModeConfiguration.self)!.version == ModeConfiguration.currentVersion, "Migration not persisted")
            }),
            ("Failed v2 migration leaves the original file intact for retry", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 2
                legacy.baseRules = LegacyPromptsV2.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV2.sceneRules(for: scene), builtin: scene)
                }
                try f.file("modes").save(legacy)
                f.failingFiles.insert("modes")
                try check(f.modes.loadError != nil, "Migration failure hidden")
                let persisted = try f.file("modes").read(ModeConfiguration.self)!
                try check(persisted.version == 2 && persisted.baseRules == LegacyPromptsV2.baseRules, "Failed migration overwrote file")
                f.failingFiles = []
                f.modes.reload()
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "Retry failed")
            }),
            ("Legacy v4 constants match the pre-rename raw transcript defaults", {
                try check(LegacyPromptsV4.rawTranscriptName == "原样转写", "Legacy v4 raw name drifted")
                try check(LegacyPromptsV4.rawTranscriptRules.contains("保留原始转录"), "Legacy v4 raw rules drifted")
                try check(LegacyPromptsV4.rawTranscriptRules != PromptComposer.defaultSceneRules(for: .rawTranscript), "v4 and v5 raw rules must differ")
            }),
            ("v4 configuration refreshes untouched raw transcript rules and name, preserves user edits", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 4
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID,
                                   name: scene == .rawTranscript ? LegacyPromptsV4.rawTranscriptName : scene.rawValue,
                                   sceneRules: scene == .rawTranscript ? LegacyPromptsV4.rawTranscriptRules : PromptComposer.defaultSceneRules(for: scene),
                                   builtin: scene)
                }
                let customText = "我自己改过的聊天规则"
                legacy.modes[legacy.modes.firstIndex { $0.builtin == .casualChat }!].sceneRules = customText
                legacy.selectedID = WritingScene.meetingNotes.storageID
                try f.file("modes").save(legacy)
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v4 migration did not complete")
                let raw = f.modes.modes.first { $0.builtin == .rawTranscript }!
                try check(raw.name == WritingScene.rawTranscript.rawValue, "v4 raw mode not renamed")
                try check(raw.sceneRules == PromptComposer.defaultSceneRules(for: .rawTranscript), "Untouched v4 raw rules not refreshed")
                try check(f.modes.modes.first { $0.builtin == .casualChat }!.sceneRules == customText, "User edit overwritten")
                try check(f.modes.selected.builtin == .meetingNotes, "Selection lost")
                try check(try f.file("modes").read(ModeConfiguration.self)!.version == ModeConfiguration.currentVersion, "v4 migration not persisted")
            }),
            ("v4 migration preserves user-edited raw transcript rules", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 4
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID,
                                   name: scene == .rawTranscript ? LegacyPromptsV4.rawTranscriptName : scene.rawValue,
                                   sceneRules: scene == .rawTranscript ? LegacyPromptsV4.rawTranscriptRules : PromptComposer.defaultSceneRules(for: scene),
                                   builtin: scene)
                }
                let customText = "逐字输出，不要任何处理"
                legacy.modes[legacy.modes.firstIndex { $0.builtin == .rawTranscript }!].sceneRules = customText
                try f.file("modes").save(legacy)
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v4 migration did not complete")
                let raw = f.modes.modes.first { $0.builtin == .rawTranscript }!
                try check(raw.sceneRules == customText, "User-edited raw rules overwritten")
                try check(raw.name == WritingScene.rawTranscript.rawValue, "Edited raw mode not renamed")
            }),
            ("Failed v4 migration leaves the original file intact for retry", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 4
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID,
                                   name: scene == .rawTranscript ? LegacyPromptsV4.rawTranscriptName : scene.rawValue,
                                   sceneRules: scene == .rawTranscript ? LegacyPromptsV4.rawTranscriptRules : PromptComposer.defaultSceneRules(for: scene),
                                   builtin: scene)
                }
                try f.file("modes").save(legacy)
                f.failingFiles.insert("modes")
                try check(f.modes.loadError != nil, "v4 migration failure hidden")
                let persisted = try f.file("modes").read(ModeConfiguration.self)!
                try check(persisted.version == 4 && persisted.modes.first { $0.builtin == .rawTranscript }!.name == LegacyPromptsV4.rawTranscriptName, "Failed v4 migration overwrote file")
                f.failingFiles = []
                f.modes.reload()
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v4 retry failed")
            }),
            ("Legacy v5 constants match the pre-fidelity-iteration defaults", {
                try check(LegacyPromptsV5.baseRules.contains("且整理深度与原文匹配") && !LegacyPromptsV5.baseRules.contains("好像"), "Legacy v5 base rules drifted")
                try check(LegacyPromptsV5.sceneRules(for: .workMessage).contains("负责人、时间和下一步仅原文明确时保留") && !LegacyPromptsV5.sceneRules(for: .workMessage).contains("阿皮哎"), "Legacy v5 work rules drifted")
                try check(LegacyPromptsV5.sceneRules(for: .meetingNotes).contains("建议和设想不是待办") && !LegacyPromptsV5.sceneRules(for: .meetingNotes).contains("关键进展与讨论"), "Legacy v5 meeting rules drifted")
                try check(LegacyPromptsV5.rawTranscriptRules.contains("按语义自然分段") && !LegacyPromptsV5.rawTranscriptRules.contains("自我更正"), "Legacy v5 raw rules drifted")
                try check(LegacyPromptsV5.baseRules != PromptComposer.defaultBaseRules, "v5 and v6 base rules must differ")
                for scene in WritingScene.allCases {
                    try check(LegacyPromptsV5.sceneRules(for: scene) != PromptComposer.defaultSceneRules(for: scene), "v5 and v6 rules must differ for \(scene.rawValue)")
                }
            }),
            ("v5 configuration refreshes untouched built-in rules and preserves user edits", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 5
                legacy.baseRules = LegacyPromptsV5.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV5.sceneRules(for: scene), builtin: scene)
                }
                let customText = "我自己改过的指令规则"
                legacy.modes[legacy.modes.firstIndex { $0.builtin == .aiInstruction }!].sceneRules = customText
                legacy.selectedID = WritingScene.meetingNotes.storageID
                try f.file("modes").save(legacy)
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v5 migration did not complete")
                try check(f.modes.configuration.baseRules == PromptComposer.defaultBaseRules, "Base rules not refreshed")
                try check(f.modes.selected.builtin == .meetingNotes, "Selection lost")
                for scene in WritingScene.allCases where scene != .aiInstruction {
                    try check(f.modes.modes.first { $0.builtin == scene }!.sceneRules == PromptComposer.defaultSceneRules(for: scene), "Untouched v5 rules not refreshed for \(scene.rawValue)")
                }
                try check(f.modes.modes.first { $0.builtin == .aiInstruction }!.sceneRules == customText, "User edit overwritten")
                try check(try f.file("modes").read(ModeConfiguration.self)!.version == ModeConfiguration.currentVersion, "v5 migration not persisted")
            }),
            ("Failed v5 migration leaves the original file intact for retry", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 5
                legacy.baseRules = LegacyPromptsV5.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV5.sceneRules(for: scene), builtin: scene)
                }
                try f.file("modes").save(legacy)
                f.failingFiles.insert("modes")
                try check(f.modes.loadError != nil, "v5 migration failure hidden")
                let persisted = try f.file("modes").read(ModeConfiguration.self)!
                try check(persisted.version == 5 && persisted.baseRules == LegacyPromptsV5.baseRules, "Failed v5 migration overwrote file")
                f.failingFiles = []
                f.modes.reload()
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v5 retry failed")
            }),
            ("v6 migration refreshes only exact defaults and preserves custom rules and selection", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 6
                legacy.baseRules = LegacyPromptsV6.baseRules + "\n我的附加规则"
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV6.sceneRules(for: scene), builtin: scene)
                }
                let edited = "我编辑过的聊天规则"
                legacy.modes[legacy.modes.firstIndex { $0.builtin == .casualChat }!].sceneRules = edited
                let custom = ModeDefinition(id: UUID().uuidString, name: "自定义回答", sceneRules: "直接回答我的问题")
                legacy.modes.append(custom)
                legacy.selectedID = custom.id
                try f.file("modes").save(legacy)
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "v6 migration failed")
                try check(f.modes.configuration.baseRules == legacy.baseRules, "Edited base overwritten")
                try check(f.modes.selected == custom && f.modes.customModes == [custom], "Custom mode or selection lost")
                try check(f.modes.modes.first { $0.builtin == .casualChat }!.sceneRules == edited, "Edited scene overwritten")
                for scene in WritingScene.allCases where scene != .casualChat {
                    try check(f.modes.modes.first { $0.builtin == scene }!.sceneRules == PromptComposer.defaultSceneRules(for: scene), "Default not refreshed")
                }
                let migrated = f.modes.configuration
                f.modes.reload()
                try check(f.modes.configuration == migrated, "Reload changed migrated rules")
            }),
            ("Failed v6 migration keeps the source file and retries the untouched base", {
                let f = ConfigurationFixture()
                var legacy = ModeConfiguration()
                legacy.version = 6
                legacy.baseRules = LegacyPromptsV6.baseRules
                legacy.modes = WritingScene.allCases.map { scene in
                    ModeDefinition(id: scene.storageID, name: scene.rawValue,
                                   sceneRules: LegacyPromptsV6.sceneRules(for: scene), builtin: scene)
                }
                try f.file("modes").save(legacy)
                f.failingFiles.insert("modes")
                try check(f.modes.loadError != nil, "Migration failure hidden")
                try check(try f.file("modes").read(ModeConfiguration.self)! == legacy, "Failed migration modified source")
                f.failingFiles = []
                f.modes.reload()
                try check(f.modes.loadError == nil && f.modes.configuration.version == ModeConfiguration.currentVersion, "Migration retry failed")
                try check(f.modes.configuration.baseRules == PromptComposer.defaultBaseRules, "Untouched base not updated")
            }),
            ("Evaluation prompt exports match compiled App composition and exact v6 migration defaults", {
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("SpokenTests/Offline/Fixtures/prompt-v7")
                func snapshot(_ name: String) throws -> [String: Any] {
                    try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as! [String: Any]
                }
                let baseline = try snapshot("baseline-prompts.json")
                let current = try snapshot("candidate-13-prompts.json")
                try check(baseline["base_rules"] as? String == LegacyPromptsV6.baseRules, "v6 base snapshot drift")
                let oldTasks = baseline["tasks"] as! [String: String]
                let newTasks = current["tasks"] as! [String: String]
                for scene in WritingScene.allCases {
                    let old = "# 基础规则\n" + LegacyPromptsV6.baseRules + "\n\n# 当前场景：" + scene.rawValue + "\n" + LegacyPromptsV6.sceneRules(for: scene)
                    try check(oldTasks[scene.storageID] == old, "v6 scene snapshot drift: \(scene.rawValue)")
                    let compiled = PromptComposer.systemPrompt(mode: .preset(scene), baseRules: PromptComposer.defaultBaseRules,
                        language: .original, personalContext: nil)
                    try check(compiled == newTasks[scene.storageID]! + "\n\n" + (current["output_contract"] as! String), "Evaluation differs from compiled App: \(scene.rawValue)")
                }
            }),
            ("Clean connection installation never reads legacy Keychain", {
                let f = ConfigurationFixture(); f.keys.failRead = true
                try check(f.connections.loadError == nil && f.connections.connections.isEmpty, "Clean install attempted legacy key read")
                try check(f.keys.reads == 0, "Clean install accessed Keychain")
            }),
            ("Legacy connection migration preserves models and copies key only to active connection", {
                let f = ConfigurationFixture(["llm_provider": "custom", "llm_custom_base_url": ModelProvider.qwen.baseURL,
                    "llm_custom_model": "qwen3.8-flash", "llm_enable_thinking": true,
                    "llm_config_minimax_fast": ["baseURL": "https://example.com/v1", "model": "old-custom-model"]])
                f.keys.legacy = "only-active-key"
                let active = f.connections.active!
                try check(active.baseURL == ModelProvider.qwen.baseURL && active.model == "qwen3.8-flash", "Active configuration changed")
                try check(!active.thinkingEnabled, "Qwen inherited DeepSeek thinking preference")
                try check(try f.connections.key(for: active) == "only-active-key", "Active key not migrated")
                let inactive = f.connections.connections.first { $0.id != active.id }!
                try check(inactive.model == "old-custom-model" && inactive.credentialID == nil, "Inactive configuration borrowed key or lost customization")
                let before = f.keys.values
                f.connections.reload()
                try check(f.keys.values == before, "Migration duplicated keys")
            }),
            ("Connection migration failure leaves legacy credentials intact", {
                let f = ConfigurationFixture(["llm_provider": "deepseek"])
                f.keys.legacy = "legacy"; f.keys.failRead = true
                try check(f.connections.loadError != nil, "Locked Keychain hidden")
                try check(!FileManager.default.fileExists(atPath: f.file("connections").url.path), "Migration committed without reading key")
                f.keys.failRead = false; f.failingFiles.insert("connections"); f.connections.reload()
                try check(f.connections.loadError != nil && f.keys.values.isEmpty, "Failed migration leaked staged key")
                try check(f.keys.legacy == "legacy", "Legacy credential deleted")
                f.failingFiles = []; f.connections.reload()
                try check(f.connections.loadError == nil && f.connections.active?.model == "deepseek-chat", "Retry changed legacy model")
            }),
            ("Connection keys are isolated and a failed save rolls back both key and configuration", {
                let f = ConfigurationFixture()
                let first = try f.connections.save(.preset(.qwen), key: "qwen-key")
                let second = try f.connections.save(.preset(.kimi), key: "kimi-key")
                try f.connections.select(second.id)
                try check(try f.connections.key(for: f.connections.active!) == "kimi-key", "Selected wrong key")
                let oldKeys = f.keys.values
                var edited = first; edited.model = "edited-model"
                f.failingFiles.insert("connections")
                try mustThrow { try f.connections.save(edited, key: "replacement-key") }
                try check(f.keys.values == oldKeys && f.connections.connections[0] == first, "Write failure replaced active configuration")
                f.failingFiles = []; f.keys.failWrite = true
                try mustThrow { try f.connections.save(edited, key: "replacement-key") }
                try check(f.keys.values == oldKeys, "Keychain failure destroyed old credential")
                f.keys.failWrite = false
                let saved = try f.connections.save(edited, key: "replacement-key")
                try check(saved.credentialID != first.credentialID && f.keys.values[first.credentialID!] == nil, "Credential rotation failed")
                try check(try f.connections.key(for: second) == "kimi-key", "Saving Qwen touched Kimi key")
                try f.connections.delete(second.id)
                try check(f.connections.active == nil && f.keys.values[second.credentialID!] == nil, "Deleting active connection silently chose another model")
            }),
            ("API and Token Plan use separate keys; editor switching cannot reuse another channel key", {
                let f = ConfigurationFixture()
                let api = try f.connections.save(.preset(.minimax), key: "api-key")
                var plan = ModelConnection.preset(.minimax); plan.name = "MiniMax 订阅"; plan.access = .tokenPlan
                let saved = try f.connections.save(plan, key: "plan-key")
                let editor = ConnectionEditor(store: f.connections)
                editor.load(saved)
                try check(editor.key == "plan-key", "Loading subscription cleared its key")
                editor.changeAccess(.api)
                try check(editor.key.isEmpty && editor.draft.credentialID == nil, "Channel switch retained old key")
                editor.load(api); editor.changeProvider(.kimi)
                try check(editor.key.isEmpty && editor.draft.baseURL == ModelProvider.kimi.baseURL, "Vendor switch borrowed key")
                f.keys.failRead = true; editor.load(api)
                try check(editor.keyLoadFailed, "Read failure became an empty editable key")
                try mustThrow { try editor.save() }
            }),
            ("Provider adapters emit supported thinking and token parameters only", {
                for provider in ModelProvider.allCases where provider != .custom {
                    let connection = ModelConnection.preset(provider)
                    let adapter = ModelRequestAdapter(connection: connection)
                    let disabled = adapter.parameters(thinkingEnabled: false, outputTokens: 8192)
                    let enabled = adapter.parameters(thinkingEnabled: true, outputTokens: 8192)
                    if provider == .qwen {
                        try check(disabled["enable_thinking"] as? Bool == false && enabled["enable_thinking"] as? Bool == true, "Qwen toggle wrong")
                        try check(disabled["temperature"] as? Double == 0, "Qwen temperature changed")
                    } else {
                        try check((disabled["thinking"] as? [String: String])?["type"] == "disabled", "Thinking not explicitly disabled")
                        try check((enabled["thinking"] as? [String: String])?["type"] == (provider == .minimax ? "adaptive" : "enabled"), "Wrong native thinking parameter")
                        try check(disabled["temperature"] == nil && disabled["enable_thinking"] == nil, "Unsupported shared parameters leaked")
                    }
                    try check(disabled[provider == .minimax ? "max_completion_tokens" : "max_tokens"] as? Int == 8192, "Wrong token field")
                }
                var old = ModelConnection.preset(.minimax); old.model = "MiniMax-M2.5"
                let adapter = ModelRequestAdapter(connection: old)
                try check(!adapter.supportsThinkingToggle && adapter.usesThinking(false), "M2 falsely advertised thinking off")
                try check(adapter.parameters(thinkingEnabled: false, outputTokens: 1000)["reasoning_split"] as? Bool == true, "MiniMax reasoning not separated")
                var unknown = ModelConnection.preset(.custom); unknown.model = "qwen3.8-flash"
                unknown.baseURL = "https://dashscope.aliyuncs.com.example.org/v1"
                try check(!ModelRequestAdapter(connection: unknown).supportsThinkingToggle, "Spoofed host matched capabilities")
            }),
            ("Endpoint normalization accepts full endpoints and rejects credential-bearing URLs", {
                try check(AIProcessingService.chatEndpoint(for: "https://example.com/v1/")?.absoluteString == "https://example.com/v1/chat/completions", "Trailing slash not normalized")
                try check(AIProcessingService.chatEndpoint(for: "https://example.com/v1/chat/completions")?.path == "/v1/chat/completions", "Full endpoint duplicated")
                for bad in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "not-a-url"] {
                    try check(AIProcessingService.chatEndpoint(for: bad) == nil, "Unsafe URL accepted")
                }
                try check(AIProcessingService.chatEndpoint(for: "http://localhost:1234/v1") != nil, "Local compatible server rejected")
            }),
            ("New prompt transport separates system rules from dictated text and preserves custom formatting", {
                let config = ConfigurationFixture()
                let mode = config.modes.draft()
                try config.modes.save(mode, baseRules: "共同规则")
                try config.modes.select(mode.id)
                _ = try config.connections.save(.preset(.kimi), key: "synthetic-key")
                let snapshot = try AIProcessingSnapshot.capture(modes: config.modes, connections: config.connections, defaults: config.defaults)
                let expected = "以下是整理后的内容：\n```swift\nlet value = \"ＡＢＣ\"\n```"
                MockProtocol.reset([.init(json: answer(expected))])
                let f = Fixture(); let service = f.service()
                var result: Result<String, Error>?
                service.process(text: input, snapshot: snapshot) { result = $0 }
                spin(3, until: { result != nil })
                try check(try result?.get() == expected, "Custom Markdown, prefix or Unicode was rewritten")
                let sent = try body(); let messages = sent["messages"] as! [[String: String]]
                try check(messages.count == 2 && messages[0]["role"] == "system" && messages[1]["content"] == input, "Transcript mixed into rules")
                try check(!messages[0]["content"]!.contains(input) && messages[0]["content"] == PromptComposer.enforcingOutputContract(PromptComposer.defaultCustomRules) && !messages[0]["content"]!.contains("共同规则"), "System prompt incorrect")
                try check(sent["max_tokens"] as? Int == 8192 && sent["temperature"] == nil, "Custom generation uses short-input budget or invalid Kimi temperature")
            }),
            ("Raw transcript snapshot composes light-cleanup prompt; translation adds output language", {
                let f = ConfigurationFixture()
                _ = try f.connections.save(.preset(.qwen), key: "test")
                let raw = try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults)
                try check(raw.mode.builtin == .rawTranscript && raw.systemPrompt.contains("流畅转写"), "Raw cleanup prompt missing")
                try check(raw.apiKey == "test" && f.keys.reads > 0, "Raw snapshot skipped key read")
                f.defaults.set(TranslateLanguage.english.rawValue, forKey: "translateLang")
                let translated = try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults)
                try check(translated.systemPrompt.contains("最终输出语言必须是英文") && translated.systemPrompt.contains(PromptComposer.defaultSceneRules(for: .rawTranscript)), "Raw translation path lost")
            }),
            ("Stop captures all settings before ASR finishes; retry never rereads edited or deleted configuration", {
                let c = ConfigurationFixture([PersonalContextStore.contextKey: "领域：OLD-CONTEXT"])
                let mode = c.modes.draft()
                try c.modes.save(mode, baseRules: "OLD-BASE")
                try c.modes.select(mode.id)
                let connection = try c.connections.save(.preset(.qwen), key: "old-key")
                let f = Fixture(); let service = f.service(timeout: 3)
                var stopped = false
                let vm = RecordingViewModel(snapshotProvider: { try AIProcessingSnapshot.capture(modes: c.modes, connections: c.connections, defaults: c.defaults) },
                    modeNameProvider: { "synthetic" }, processor: service, stopCapture: { stopped = true }, cancelCapture: {})
                vm.isRecording = true; vm.stopRecording()
                try check(stopped && vm.frozenConfiguration != nil && !vm.isRecording, "Stop did not freeze settings")
                try c.modes.delete(mode.id)
                try c.connections.delete(connection.id)
                c.defaults.set("NEW-CONTEXT", forKey: PersonalContextStore.contextKey)
                c.defaults.set(TranslateLanguage.japanese.rawValue, forKey: "translateLang")
                MockProtocol.reset([.init(json: [:], error: URLError(.networkConnectionLost)), .init(json: answer("回答"))])
                var output: String?
                vm.onComplete = { value, _ in output = value }
                vm.processAndInput(input)
                spin(4, until: { output != nil })
                try check(output == "回答" && MockProtocol.requests.count == 2, "Frozen request failed")
                let first = try body(0); let second = try body(1)
                try check(first["model"] as? String == connection.model && second["model"] as? String == connection.model, "Retry changed model")
                let prompt = (second["messages"] as! [[String: String]])[0]["content"]!
                // 自定义模式的提示词只含用户规则原文和个人背景；冻结语义体现在重试请求与首次完全一致，
                // 且不读取删除模式后写入的新个人背景和新输出语言。
                try check(prompt.contains(PromptComposer.defaultCustomRules) && prompt.contains("OLD-CONTEXT") && prompt == ((first["messages"] as! [[String: String]])[0]["content"]!) && !prompt.contains("NEW-CONTEXT") && !prompt.contains("最终输出语言必须是日文"), "Snapshot reread rules/context/language")
                try check(MockProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer old-key" }, "Snapshot reread key")
            }),
            ("Automatic finalization freezes once and ignores duplicate or cancelled results", {
                let mode = ModeDefinition.preset(.rawTranscript)
                let snapshot = AIProcessingSnapshot(mode: mode, language: .original, systemPrompt: "", connection: nil, apiKey: "")
                var captures = 0; var outputs = 0
                let vm = RecordingViewModel(snapshotProvider: { captures += 1; return snapshot }, modeNameProvider: { "raw" }, stopCapture: {}, cancelCapture: {})
                vm.onComplete = { _, _ in outputs += 1 }
                vm.processAndInput(input); vm.processAndInput(input)
                spin(1, until: { outputs == 1 })
                try check(captures == 1 && outputs == 1, "Automatic finish repeated snapshot or output")
                vm.cancel()
                vm.finishAIProcessing(.success("迟到"), originalText: input)
                try check(outputs == 1, "Cancelled request pasted text")
            }),
            ("Custom requests use the full generation deadline and retain literal reasoning tags in code", {
                let f = Fixture()
                let service = AIProcessingService(defaults: f.defaults, session: f.session, recordsMetrics: false, log: { _ in })
                let mode = ModeDefinition(id: UUID().uuidString, name: "写代码", sceneRules: "输出代码")
                let snapshot = AIProcessingSnapshot(mode: mode, language: .original, systemPrompt: "写代码", connection: .preset(.qwen), apiKey: "synthetic-key")
                let output = "```html\n<think>literal markup</think>\n```"
                MockProtocol.reset([.init(json: answer(output))])
                var result: Result<String, Error>?
                service.process(text: "写一个例子", snapshot: snapshot) { result = $0 }
                spin(2, until: { result != nil })
                try check(try result?.get() == output, "Literal code markup was removed")
                try check(MockProtocol.requests.first?.timeoutInterval == 60, "Custom mode kept short-input deadline")
                try check(try body()["max_tokens"] as? Int == 8192, "Custom output budget incorrect")
                try expectFailure(AIProcessingService.validatedOutput("<think>unfinished", stripWrappers: false), code: "unsafe_output")
            }),
            ("Locked configuration falls back to original text after finalization", {
                let vm = RecordingViewModel(snapshotProvider: { throw ConfigurationError.unavailable("locked") }, modeNameProvider: { "test" }, stopCapture: {}, cancelCapture: {})
                var output: String?
                vm.onComplete = { value, _ in output = value }
                vm.isRecording = true; vm.stopRecording(); vm.processAndInput(input)
                try check(output == input && vm.fallbackNotice != nil, "Capture failure lost original transcript")
            })
        ]
    }
}

private extension AIProcessingRegression {
    @MainActor
    static func launchInteractiveSmoke() throws {
        let fixture = ConfigurationFixture([PersonalContextStore.contextKey: "领域：合成测试。表达习惯：简洁直接。"])
        var mode = fixture.modes.draft(); mode.name = "合成问答"
        try fixture.modes.save(mode, baseRules: fixture.modes.configuration.baseRules)
        _ = try fixture.connections.save(.preset(.qwen), key: "synthetic-smoke-key")
        _ = try fixture.connections.save(.preset(.minimax), key: "synthetic-minimax-key")
        let transport = Fixture()
        // Leave time to exercise cancellation and the disabled scene picker in the interactive harness.
        MockProtocol.reset(Array(repeating: .init(json: answer("OK · 本地模拟结果"), delay: 15), count: 100))
        let service = AIProcessingService(defaults: fixture.defaults, session: transport.session, recordsMetrics: false, log: { _ in })
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Spoken 本地冒烟", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 160, y: 100, width: 1020, height: 810),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Spoken 本地冒烟 · 合成数据 / 模拟模型"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InteractiveSmokeView(fixture: fixture, service: service))
        window.center(); window.makeKeyAndOrderFront(nil)
        app.run()
        withExtendedLifetime((fixture, transport, service, window)) {}
    }

    @MainActor
    static func reviewTests() -> [(String, () throws -> Void)] {
        [
            ("Injected UI stores never initialize production configuration", {
                let f = ConfigurationFixture()
                let transport = Fixture()
                let service = transport.service()
                let menu = ContentView(onOpenSettings: { _ in }, modes: f.modes, connections: f.connections, speechConnections: f.speechConnections, hotkeys: f.hotkeys, accessibility: f.accessibility, defaults: f.defaults)
                let settings = SettingsView(modes: f.modes, connections: f.connections, hotkeys: f.hotkeys, accessibility: f.accessibility, defaults: f.defaults,
                    speechDependencies: f.speechSettings, connectionTestService: service)
                let vm = RecordingViewModel(snapshotProvider: { try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults) },
                    modeNameProvider: { f.modes.selected.name }, processor: service, stopCapture: {}, cancelCapture: {})
                let panel = RecordingPanelView(viewModel: vm, modes: f.modes, hotkeys: f.hotkeys, accessibility: f.accessibility)
                _ = menu.body; _ = settings.body; _ = panel.body
                try check(menu.hotkeys === f.hotkeys && settings.hotkeys === f.hotkeys && panel.hotkeys === f.hotkeys, "Hotkey UI escaped injected service")
                try check(menu.modes === f.modes && settings.connections === f.connections && panel.modes === f.modes,
                          "Views lost injected stores")
                try check(f.keys.reads == 0, "View initialization unexpectedly read credentials")
            }),
            ("Deleting a mode retains unsaved global rules and saving applies them to the next mode", {
                let f = ConfigurationFixture()
                let mode = f.modes.draft()
                try f.modes.save(mode, baseRules: "saved base")
                try f.modes.select(mode.id)
                let editor = ModeEditor(store: f.modes)
                editor.baseRules = "pending global rules"
                editor.draft.sceneRules = "pending scene rules"
                try editor.delete()
                try check(editor.draft.builtin == .rawTranscript && editor.isDirty, "Delete silently discarded global draft")
                try check(editor.baseRules == "pending global rules" && f.modes.configuration.baseRules == "saved base", "Delete persisted or lost unrelated rules")
                try editor.save()
                try check(f.modes.configuration.baseRules == "pending global rules" && !editor.isDirty, "Remaining draft could not be saved")
            }),
            ("Draft navigation handles save, discard, cancel and failed persistence", {
                let f = ConfigurationFixture()
                let editor = ModeEditor(store: f.modes)
                var decision = SettingsNavigationGuard.Decision.cancel
                var alerts = 0; var failures = 0
                let guarder = SettingsNavigationGuard(decision: { alerts += 1; return decision }, reportFailure: { _ in failures += 1 })
                guarder.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard)
                try check(guarder.allowNavigation() && alerts == 0, "Unchanged form asked to save")
                editor.baseRules = "changed"
                try check(!guarder.allowNavigation() && editor.isDirty, "Cancel lost draft")
                decision = .save; f.failingFiles.insert("modes")
                try check(!guarder.allowNavigation() && failures == 1 && editor.isDirty, "Save failure allowed navigation")
                f.failingFiles = []
                try check(guarder.allowNavigation() && !editor.isDirty, "Save did not unblock navigation")
                editor.baseRules = "discard me"; decision = .discard
                try check(guarder.allowNavigation() && editor.baseRules == "changed", "Discard did not reload saved rules")
                editor.load(f.modes.draft()); decision = .cancel
                try check(!guarder.allowNavigation(), "Unchanged new mode was silently discarded")
            }),
            ("Retrying a locked key preserves unsaved model metadata", {
                let f = ConfigurationFixture()
                let saved = try f.connections.save(.preset(.qwen), key: "existing-key")
                let editor = ConnectionEditor(store: f.connections)
                f.keys.failRead = true; editor.load(saved)
                editor.draft.name = "unsaved name"; editor.draft.model = "unsaved-model"
                try mustThrow { try editor.save() }
                f.keys.failRead = false; editor.retryKey()
                try check(editor.key == "existing-key" && !editor.keyLoadFailed && editor.isDirty, "Retry reset draft baseline")
                try check(f.connections.active?.name == saved.name, "Retry saved metadata")
                try editor.save()
                try check(f.connections.active?.name == "unsaved name" && !editor.isDirty, "Recovered draft did not save")
            }),
            ("Connection testing is explicit, synthetic, normalized and does not save drafts", {
                let c = ConfigurationFixture([PersonalContextStore.contextKey: "PRIVATE-CONTEXT-SENTINEL"])
                let f = Fixture()
                let service = AIProcessingService(defaults: c.defaults, session: f.session, recordsMetrics: false, log: { _ in })
                let editor = ConnectionEditor(store: c.connections, testService: service)
                MockProtocol.reset([.init(json: answer("OK"))])
                editor.create(.qwen); editor.key = "  synthetic-test-key  "
                editor.draft.model = " qwen3.8-flash \n"
                editor.draft.baseURL = " " + ModelProvider.qwen.baseURL + " "
                spin(0.05)
                try check(MockProtocol.requests.isEmpty, "Editing made an unsolicited model request")
                editor.test(); spin(2, until: { !editor.testing })
                try check(editor.message.contains("连接通过") && editor.message.contains("秒"), "Test did not report elapsed time")
                let sent = try body()
                let messages = sent["messages"] as! [[String: String]]
                try check(messages == [["role": "system", "content": PromptComposer.enforcingOutputContract("仅回复 OK。")], ["role": "user", "content": "连接测试，请回复 OK。"]], "Test sent context or transcript")
                try check(sent["model"] as? String == "qwen3.8-flash" && sent["enable_thinking"] as? Bool == false, "Draft whitespace changed adapter behavior")
                try check(MockProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-key", "Test key was not normalized")
                try check(c.connections.connections.isEmpty && editor.isDirty, "Test saved the draft")
            }),
            ("Cancelled connection tests never overwrite a later connection or report success", {
                let c = ConfigurationFixture(); let f = Fixture()
                let editor = ConnectionEditor(store: c.connections, testService: f.service())
                editor.create(.qwen); editor.key = "fake"
                MockProtocol.reset([.init(json: answer("OK"), delay: 0.15)])
                editor.test(); spin(0.03)
                editor.create(.kimi)
                spin(0.25)
                try check(!editor.testing && editor.message.isEmpty && editor.error == nil && editor.draft.provider == .kimi, "Late test result leaked into new draft")
                MockProtocol.reset([]); editor.test(); spin(0.05)
                try check(MockProtocol.requests.isEmpty && editor.error != nil, "Missing key still made a request")
            }),
            ("IPv6 local URLs and completion path segments are normalized correctly", {
                try check(AIProcessingService.chatEndpoint(for: "http://[::1]:11434/v1/")?.absoluteString == "http://[::1]:11434/v1/chat/completions", "Local IPv6 rejected")
                try check(AIProcessingService.chatEndpoint(for: "http://[2001:db8::1]/v1") == nil, "Remote IPv6 allowed plain HTTP")
                try check(AIProcessingService.chatEndpoint(for: "https://example.com/v1/notchat/completions")?.path == "/v1/notchat/completions/chat/completions", "Partial path segment mistaken for endpoint")
                for invalid in ["https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "http://localhost.example.org/v1"] {
                    try check(AIProcessingService.chatEndpoint(for: invalid) == nil, "Unsafe or ambiguous endpoint accepted")
                }
            }),
            ("Corrupt configuration and invalid versions remain intact after reload and save attempts", {
                let f = ConfigurationFixture()
                _ = f.modes; _ = f.connections
                for name in ["modes", "connections", "backup"] {
                    try Data("{incomplete".utf8).write(to: f.file(name).url)
                }
                f.modes.reload(); f.connections.reload()
                try check(f.modes.loadError != nil && f.connections.loadError != nil, "Corrupt JSON silently reset")
                try mustThrow { try f.modes.save(f.modes.draft(), baseRules: "new") }
                try mustThrow { try f.connections.save(.preset(.kimi), key: "new") }
                try check(try String(contentsOf: f.file("modes").url, encoding: .utf8) == "{incomplete", "Failed load was overwritten")
                try check(f.keys.values.isEmpty, "Rejected save staged a credential")
            }),
            ("Capture-stop boundary freezes configuration before delayed automatic ASR completion", {
                let c = ConfigurationFixture()
                var captures = 0
                let vm = RecordingViewModel(snapshotProvider: {
                    captures += 1
                    return try AIProcessingSnapshot.capture(modes: c.modes, connections: c.connections, defaults: c.defaults)
                }, modeNameProvider: { c.modes.selected.name }, stopCapture: {}, cancelCapture: {})
                vm.isRecording = true; vm.isCaptureReady = false; vm.showsModes = true
                vm.captureStopped()
                try check(captures == 1 && !vm.isRecording && !vm.showsModes, "Preparation stop did not lock the UI")
                try c.modes.select(WritingScene.aiInstruction.storageID)
                var result: String?
                vm.onComplete = { text, _ in result = text }
                vm.captureStopped(); vm.processAndInput(input)
                try check(result == input && captures == 1 && vm.displayStatus == "流畅转写", "Delayed ASR captured later settings")
            }),
            ("Empty ASR and cancellation emit no text and close once", {
                var captures = 0; var closes = 0; var outputs = 0
                let vm = RecordingViewModel(snapshotProvider: { captures += 1; throw TestFailure(description: "unused") }, modeNameProvider: { "raw" }, stopCapture: {}, cancelCapture: {})
                vm.onCancel = { closes += 1 }; vm.onComplete = { _, _ in outputs += 1 }
                vm.processAndInput(""); vm.processAndInput("")
                try check(closes == 1 && outputs == 0 && captures == 0, "Empty ASR requested a model or closed twice")
                vm.cancel(); vm.cancel(); vm.processAndInput(input)
                try check(closes == 2 && outputs == 0, "Cancellation emitted or repeated callbacks")
            }),
            ("Every provider transports bounded custom generation with its own parameters", {
                for provider in ModelProvider.allCases where provider != .custom {
                    let c = ModelConnection.preset(provider)
                    let f = Fixture(); let service = f.service()
                    let mode = ModeDefinition(id: UUID().uuidString, name: "生成", sceneRules: "生成文本")
                    let snapshot = AIProcessingSnapshot(mode: mode, language: .original, systemPrompt: "生成文本", connection: c, apiKey: "synthetic")
                    MockProtocol.reset([.init(json: answer("# 标题\n\n- 一项"))])
                    var result: Result<String, Error>?
                    service.process(text: "写两行", snapshot: snapshot) { result = $0 }
                    spin(2, until: { result != nil })
                    try check(try result?.get() == "# 标题\n\n- 一项", "Provider transport failed: \(provider)")
                    let sent = try body()
                    let field = provider == .minimax ? "max_completion_tokens" : "max_tokens"
                    try check(sent[field] as? Int == 8192, "Wrong generation budget: \(provider)")
                    try check(provider == .qwen || sent["temperature"] == nil, "Forced temperature: \(provider)")
                }
            }),
            ("Tool calls, filtered results and malformed content fall back without partial output", {
                for reason in ["tool_calls", "content_filter", "length"] {
                    MockProtocol.reset([.init(json: answer("partial", reason: reason))])
                    let f = Fixture(); try expectFailure(try process(f.service()), code: "incomplete_output")
                }
                MockProtocol.reset([.init(json: ["choices": [["message": ["content": 123], "finish_reason": "stop"]]])])
                let f = Fixture(); try expectFailure(try process(f.service()), code: "parse_error")
            }),
            ("Legacy scene migration retains explicit translation and stable scene identifiers", {
                let polish = MemoryDefaults(["spokenMode": "润色", "translateLang": "英文"])
                try check(WritingScene.load(from: polish) == .casualChat && polish.string(forKey: "translateLang") == "原语言", "Legacy polish translation changed")
                let translate = MemoryDefaults(["spokenMode": "翻译", "translateLang": "日文"])
                try check(WritingScene.load(from: translate) == .rawTranscript && translate.string(forKey: "translateLang") == "日文", "Legacy translation lost")
                let modern = MemoryDefaults([WritingScene.defaultsKey: "正式材料", "spokenMode": "直接输入"])
                try check(WritingScene.load(from: modern) == .formalDocument && modern.string(forKey: WritingScene.defaultsKey) == "formal_document", "Stable ID migration failed")
                WritingScene.contentShare.save(to: modern)
                try check(WritingScene.load(from: modern) == .contentShare, "Stable selection did not reload")
            }),
            ("ASR replay buffer preserves order and drops oldest data at capacity", {
                var buffer = AudioReplayBuffer(maxBytes: 5)
                buffer.append(Data([1, 2])); buffer.append(Data([3, 4]))
                try check(buffer.buffers == [Data([1, 2]), Data([3, 4])] && buffer.byteCount == 4, "Audio reordered")
                buffer.append(Data([5, 6, 7]))
                try check(buffer.buffers == [Data([3, 4]), Data([5, 6, 7])] && buffer.byteCount == 5, "Capacity eviction incorrect")
                buffer.removeAll()
                try check(buffer.byteCount == 0 && buffer.buffers.isEmpty, "Replay reset retained audio")
            }),
            ("Synthetic 48 kHz stereo audio converts to 16 kHz mono PCM without microphone access", {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
                input.frameLength = 4_800
                for channel in 0..<2 {
                    for index in 0..<4_800 { input.floatChannelData![channel][index] = sin(Float(index) * 0.01) }
                }
                guard let converter = StreamingASRPCMConverter(inputFormat: format), let pcm = converter.convert(input) else {
                    throw TestFailure(description: "PCM conversion failed")
                }
                try check(!pcm.isEmpty && pcm.count % 2 == 0 && pcm.count <= 3_200, "Unexpected PCM format/length")
            }),
            ("ASR final fallback preserves recognized words without fixed replacements", {
                try check(CloudRecognitionResultResolver.best(cloudText: "最终结果", latestPartial: "临时") == "最终结果", "Final lost")
                for final: String? in [nil, " \n"] {
                    try check(CloudRecognitionResultResolver.best(cloudText: final, latestPartial: "临时") == "临时", "Partial lost on empty final")
                }
                for text in [
                    "我们的愿景是开放源码，同时记录地图经纬度和老虎的踪迹。",
                    "我家养了一只八哥，欧凯负责照顾它。",
                    "这个八哥要调用阿皮哎",
                    "阿皮哎、爱劈唉、诶批艾、艾斯迪凯、埃斯迪凯、八哥、巴格、欧克、欧凯"
                ] {
                    try check(SpeechPostProcessor.postProcess(text) == text, "Recognized words were replaced")
                }
                try check(SpeechPostProcessor.postProcess("调用 A P I 和 S D K") == "调用 API 和 SDK", "Acronym spacing changed")
            }),
            ("Warm ASR reuse requires every health and identity condition", {
                for failingCondition in -1..<7 {
                    let reused = WarmConnectionReusePolicy.canReuse(age: failingCondition == 0 ? 181 : 30, maxAge: 180,
                        sameAPIKey: failingCondition != 1, sameModel: failingCondition != 2, sameEndpoint: failingCondition != 3,
                        hasTransport: failingCondition != 4, hasMissedHeartbeat: failingCondition == 5)
                    try check(reused == (failingCondition == -1 || failingCondition == 6), "Unhealthy warm session reused")
                }
            }),
            ("Qwen handshake and workspace endpoint rules match protocol boundaries", {
                try check(QwenSessionHandshakePolicy.action(for: "session.created") == .noteSessionCreated, "Created event prematurely ready")
                try check(QwenSessionHandshakePolicy.action(for: "session.updated") == .markReady, "Update did not become ready")
                try check(QwenSessionHandshakePolicy.action(for: "other") == .ignore, "Unknown event accepted")
                try check(QwenEndpointResolver.host(workspaceID: " ws-123 ") == "ws-123.cn-beijing.maas.aliyuncs.com", "Workspace endpoint wrong")
                try check(QwenEndpointResolver.host(workspaceID: "invalid.example.com") == "dashscope.aliyuncs.com", "Invalid workspace accepted")
            }),
            ("Voice activity detector rejects silence; latency percentiles remain correct", {
                try check(!PCMVoiceActivityDetector.containsMeaningfulSpeech(Data(repeating: 0, count: 4096)), "Silence counted as speech")
                var samples = [Int16](repeating: 0, count: 2048)
                for index in 0..<64 { samples[index] = index.isMultiple(of: 2) ? 2000 : -2000 }
                try check(PCMVoiceActivityDetector.containsMeaningfulSpeech(samples.withUnsafeBytes { Data($0) }), "Synthetic speech not detected")
                let d = PipelineLatencyMetrics.distribution([0.1, 0.2, 0.3, 0.4, 0.5])
                try check(d.count == 5 && d.p50 == 0.3 && d.p90 == 0.5 && d.p95 == 0.5, "Latency percentiles wrong")
            })
        ]
    }

    @MainActor
    static func renderInterfaceSamples(at directory: URL) throws {
        // Only synthetic configuration and in-memory keys. Never instantiate the real AppDelegate.
        StateManager.shared.transition(to: .idle)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fixture = ConfigurationFixture()
        for (name, rules) in [("英文邮件", "把语音整理为一封自然、简洁的英文邮件。"),
                              ("直接问答", "回答问题，先给结论，再列要点。"),
                              ("一个特别长的自定义模式名称用于检查布局", "生成简洁的工作清单。") ] {
            var mode = fixture.modes.draft(); mode.name = name; mode.sceneRules = rules
            try fixture.modes.save(mode, baseRules: fixture.modes.configuration.baseRules)
        }
        try fixture.modes.select(WritingScene.aiInstruction.storageID)
        for provider in ModelProvider.allCases where provider != .custom {
            _ = try fixture.connections.save(.preset(provider), key: "synthetic-preview-key")
        }
        try fixture.connections.select(fixture.connections.connections.last!.id)
        for vendor in SpeechVendor.allCases {
            var sample = speechSample(vendor)
            if vendor == .custom {
                var c = sample.connection; c.name = "一个特别长的自定义语音连接名称用于检查布局"
                sample = SpeechSessionSnapshot(connection: c, credentials: sample.credentials)
            }
            try fixture.speechConnections.save(sample.connection, credentials: sample.credentials, engine: .cloud)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool) throws {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: size)
            let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentView = host
            panel.setFrameOrigin(NSPoint(x: -3000, y: 0))
            panel.orderFront(nil)
            spin(0.35)
            host.layoutSubtreeIfNeeded()
            if name.hasPrefix("menu-") {
                func containsScrollView(_ view: NSView) -> Bool {
                    view is NSScrollView || view.subviews.contains(where: containsScrollView)
                }
                try check(!containsScrollView(host), "Mode panel unexpectedly requires scrolling: \(name)")
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure(description: "Cannot allocate UI bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure(description: "Cannot encode UI bitmap") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            panel.orderOut(nil)
            print("Rendered: \(name) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
        }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections, speechConnections: fixture.speechConnections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults),
                       name: "menu-\(theme)", size: NSSize(width: 380, height: ContentView.panelHeight), dark: dark)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, initialSection: .modes, defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "modes-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, initialSection: .models, defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "models-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility,
                                    initialSection: .shortcuts, defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "shortcuts-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            fixture.hotkeyRegistrar.occupied.insert(fixture.hotkeys.configuration); fixture.hotkeys.recheck()
            try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections, speechConnections: fixture.speechConnections,
                                   hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults),
                       name: "menu-conflict-\(theme)", size: NSSize(width: 380, height: ContentView.panelHeight), dark: dark)
            fixture.hotkeyRegistrar.occupied.removeAll(); fixture.hotkeys.recheck()
            fixture.defaults.set(SpeechRecognitionProvider.cloud.rawValue, forKey: "speechRecognitionProvider")
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, initialSection: .speech,
                                    defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "speech-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            for connection in fixture.speechConnections.connections {
                try fixture.speechConnections.select(connection.id, engine: .cloud)
                try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility,
                                        initialSection: .speech, defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                           name: "speech-\(connection.vendor.rawValue)-minimum-\(theme)", size: NSSize(width: 820, height: 580), dark: dark)
            }
            fixture.defaults.set("领域：合成测试。表达习惯：简洁直接。", forKey: PersonalContextStore.contextKey)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, initialSection: .context,
                                    defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "context-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            fixture.permissionState = .notAuthorized; fixture.accessibility.refresh()
            try render(AccessibilityGuideView(service: fixture.accessibility, onLater: {}), name: "permission-guide-\(theme)",
                       size: NSSize(width: 480, height: 580), dark: dark)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility,
                                    initialSection: .permissions, defaults: fixture.defaults, speechDependencies: fixture.speechSettings), name: "permissions-minimum-\(theme)",
                       size: NSSize(width: 820, height: 580), dark: dark)
            try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections, speechConnections: fixture.speechConnections,
                                   hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults, panelHeight: 300),
                       name: "menu-permissions-minimum-\(theme)", size: NSSize(width: 380, height: 300), dark: dark)
            try render(TextDeliveryNotice(message: "文字已复制。辅助功能尚未授权或生效，请回到输入框按 ⌘V 粘贴。", onAuthorize: {}, onDismiss: {}),
                       name: "permission-delivery-\(theme)", size: NSSize(width: 420, height: 132), dark: dark)
            let vm = RecordingViewModel(snapshotProvider: { throw TestFailure(description: "Preview cannot process") }, modeNameProvider: { "AI 指令" }, stopCapture: {}, cancelCapture: {})
            vm.isRecording = true; vm.isCaptureReady = true; vm.showsModes = true
            vm.statusText = "这是一段合成语音，用于界面检查。"
            try render(RecordingPanelView(viewModel: vm, modes: fixture.modes, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility), name: "recording-\(theme)",
                       size: NSSize(width: 420, height: vm.panelHeight), dark: dark)
            vm.showsModes = false; vm.hasRecoverableInput = true
            try render(RecordingPanelView(viewModel: vm, modes: fixture.modes, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility), name: "recording-recovery-ready-\(theme)",
                       size: NSSize(width: 420, height: vm.panelHeight), dark: dark)
            vm.hasDetectedSpeech = true
            vm.partialText = "环境声触发的临时识别"
            vm.statusText = vm.partialText
            try render(RecordingPanelView(viewModel: vm, modes: fixture.modes, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility), name: "recording-recovery-speaking-\(theme)",
                       size: NSSize(width: 420, height: vm.panelHeight), dark: dark)
            let recoveryFixture = try RecoveryFixture()
            let recovery = recoveryFixture.recovery!
            try recoveryFixture.config.modes.select(WritingScene.workMessage.storageID)
            recovery.capture("嗯那个评审改到周五下午三点吧，方案我明天发，预算这块先别定，还得等财务确认。")
            recovery.prepareForPresentation()
            try render(InputRecoveryView(recovery: recovery, onClose: {}), name: "recovery-original-\(theme)", size: InputRecoveryView.size, dark: dark)
            recovery.selectMode(WritingScene.meetingNotes.storageID); recovery.reprocess()
            try render(InputRecoveryView(recovery: recovery, onClose: {}), name: "recovery-running-\(theme)", size: InputRecoveryView.size, dark: dark)
            recoveryFixture.processor.requests.last!.finish(.success("评审：周五下午三点。\n方案：明天发送。\n预算：等待财务确认。"))
            spin(0.1, until: { !recovery.isProcessing })
            recovery.selectMode(WritingScene.formalDocument.storageID)
            try render(InputRecoveryView(recovery: recovery, onClose: {}), name: "recovery-result-new-scene-\(theme)", size: InputRecoveryView.size, dark: dark)
            var longMode = recoveryFixture.config.modes.draft()
            longMode.name = "一个特别长的自定义场景名称用于检查找回页布局"
            try recoveryFixture.config.modes.save(longMode, baseRules: recoveryFixture.config.modes.configuration.baseRules)
            recovery.selectMode(longMode.id)
            try render(InputRecoveryView(recovery: recovery, onClose: {}), name: "recovery-long-scene-\(theme)", size: InputRecoveryView.size, dark: dark)
            recovery.capture(String(repeating: "这是一段需要核对的较长原始口述。预算还要等财务确认。\n", count: 25), mayBeIncomplete: true)
            recovery.reprocess(); recoveryFixture.processor.requests.last!.finish(.failure(MiniMaxError.timeout))
            spin(0.1, until: { !recovery.isProcessing })
            try render(InputRecoveryView(recovery: recovery, onClose: {}), name: "recovery-long-failure-\(theme)", size: InputRecoveryView.size, dark: dark)
            fixture.permissionState = .ready; fixture.accessibility.refresh()
        }
        try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections, speechConnections: fixture.speechConnections,
                               hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults, panelHeight: 300),
                   name: "menu-minimum", size: NSSize(width: 380, height: 300), dark: false)
        fixture.hotkeyRegistrar.occupied.insert(fixture.hotkeys.configuration); fixture.hotkeys.recheck()
        try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections, speechConnections: fixture.speechConnections,
                               hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults, panelHeight: 300),
                   name: "menu-conflict-minimum", size: NSSize(width: 380, height: 300), dark: true)
        fixture.hotkeyRegistrar.occupied.removeAll(); fixture.hotkeys.recheck()
        try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults, speechDependencies: fixture.speechSettings), name: "settings-minimum",
                   size: NSSize(width: 820, height: 580), dark: false)
        try render(SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility,
                                initialSection: .shortcuts, defaults: fixture.defaults, speechDependencies: fixture.speechSettings), name: "shortcuts-minimum",
                   size: NSSize(width: 820, height: 580), dark: false)
        // Crowded and first-launch states must also fit without a scrolling container.
        try Data("invalid-preview-json".utf8).write(to: fixture.file("connections").url)
        fixture.connections.reload()
        fixture.permissionState = .notAuthorized; fixture.accessibility.refresh()
        fixture.hotkeyRegistrar.occupied.insert(fixture.hotkeys.configuration); fixture.hotkeys.recheck()
        let empty = ConfigurationFixture()
        empty.permissionState = .notAuthorized
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for height: CGFloat in [300, 440] {
                try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections,
                                       speechConnections: fixture.speechConnections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility,
                                       defaults: fixture.defaults, panelHeight: height),
                           name: "menu-errors-\(Int(height))-\(theme)", size: NSSize(width: 380, height: height), dark: dark)
                try render(ContentView(onOpenSettings: { _ in }, modes: empty.modes, connections: empty.connections,
                                       speechConnections: empty.speechConnections, hotkeys: empty.hotkeys, accessibility: empty.accessibility,
                                       defaults: empty.defaults, panelHeight: height),
                           name: "menu-empty-\(Int(height))-\(theme)", size: NSSize(width: 380, height: height), dark: dark)
            }
        }
        if let frontmost, let after = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            try check(after == frontmost, "Preview panels stole foreground application focus")
            print("PASS: Preview panels preserved foreground application focus")
        } else {
            print("SKIP: Foreground focus could not be read in this environment; interactive verification remains required")
        }
        print("PASS: Native light/dark/minimum-size surfaces rendered; mode panels contain no scroll views")
    }
}

/// Disposable native UI harness. Never starts AppDelegate, microphone, production Keychain or text injection.
private final class WeakRecordingModel {
    weak var value: RecordingViewModel?
}

private struct InteractiveSmokeView: View {
    let fixture: ConfigurationFixture
    let service: AIProcessingService
    @State private var showMenu = false
    @State private var settingsSection = SettingsSection.modes
    @State private var showingRecording = false
    @State private var recordingModel: RecordingViewModel?
    @State private var output = "尚未处理合成语音"
    @State private var failWrites = false
    @State private var failSpeechKeyRead = false
    @State private var recoveryPanel: InputRecoveryPanel?
    @State private var recoveryStore: InputRecoveryStore?
    @State private var failRecoveryTarget = false

    private var speechDependencies: SpeechSettingsDependencies {
        fixture.keys.failRead = failSpeechKeyRead
        fixture.keys.failWrite = failWrites
        return fixture.speechSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本地冒烟").font(.headline)
                Text("仅合成数据 · 模拟请求").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showMenu ? "返回设置" : "模式面板") { showMenu.toggle(); showingRecording = false }
                Button("模拟录音浮窗", action: showRecording)
                Button("找回输入演示", action: showRecovery)
                Toggle("模拟保存失败", isOn: $failWrites).toggleStyle(.checkbox)
                Toggle("模拟语音密钥读取失败", isOn: $failSpeechKeyRead).toggleStyle(.checkbox)
            }.padding(12)
            HStack {
                Text("辅助功能模拟").font(.caption)
                Button("未授权") { fixture.permissionState = .notAuthorized; fixture.accessibility.refresh() }
                Button("已授权") { fixture.permissionState = .ready; fixture.accessibility.refresh() }
                Button("授权未生效") { fixture.permissionState = .eventPostingDenied; fixture.accessibility.refresh() }
                Button("设置打开失败") { fixture.settingsOpenSucceeds = false; fixture.accessibility.openSettings() }
                Toggle("模拟找回目标失效", isOn: $failRecoveryTarget).toggleStyle(.checkbox)
            }.padding(8)
            Divider()
            if showingRecording, let recordingModel {
                VStack(spacing: 16) {
                    Text("录音浮窗组件 · 嵌入测试窗口，不验证跨应用焦点")
                        .font(.caption).foregroundStyle(.secondary)
                    RecordingPanelView(viewModel: recordingModel, modes: fixture.modes, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility).frame(width: 420)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showMenu {
                ContentView(onOpenSettings: { section in settingsSection = section; showMenu = false },
                            modes: fixture.modes, connections: fixture.connections, speechConnections: fixture.speechConnections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, defaults: fixture.defaults)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsView(modes: fixture.modes, connections: fixture.connections, hotkeys: fixture.hotkeys, accessibility: fixture.accessibility, initialSection: settingsSection,
                             defaults: fixture.defaults, speechDependencies: speechDependencies, connectionTestService: service)
            }
            Divider()
            HStack {
                Text("模拟输出：" + output).font(.caption).textSelection(.enabled)
                Spacer()
                if let recordingModel {
                    Button("模拟误识别") {
                        recordingModel.hasDetectedSpeech = true
                        recordingModel.partialText = "环境声触发的临时识别"
                        recordingModel.statusText = recordingModel.partialText
                    }
                    Button("完成合成语音") { recordingModel.stopRecording() }
                }
            }.padding(10)
        }
        .onChange(of: failWrites) { _, failing in fixture.failingFiles = failing ? ["modes", "connections", "hotkey-v1"] : [] }
    }

    @MainActor
    private func showRecovery() {
        recoveryPanel?.orderOut(nil)
        let recovery = recoveryStore ?? InputRecoveryStore(modes: fixture.modes, processor: service,
            snapshotProvider: { id in
                try AIProcessingSnapshot.capture(modes: fixture.modes, connections: fixture.connections, defaults: fixture.defaults, modeID: id)
            }, canStart: { true }, copyText: { value in output = "复制检查：" + value; return true })
        if recovery.entry == nil {
            recovery.capture("嗯那个评审改到周五下午三点吧，方案我明天发，预算这块先别定，还得等财务确认。")
        }
        recoveryStore = recovery
        recovery.prepareForPresentation()
        let panel = InputRecoveryPanel(contentRect: NSRect(origin: .zero, size: InputRecoveryView.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: InputRecoveryView(recovery: recovery) { [weak panel] in
            recovery.cancelProcessing(); recovery.onProcessed = nil
            panel?.orderOut(nil); panel?.contentView = nil; recoveryPanel = nil
        })
        recovery.onProcessed = { [weak panel] text in
            guard let panel, recoveryPanel === panel, panel.isVisible else { return }
            recovery.onProcessed = nil
            panel.orderOut(nil); panel.contentView = nil; recoveryPanel = nil
            // Exercise production clipboard/focus gating on a private pasteboard, without OS events.
            let pb = NSPasteboard(name: .init("spoken-recovery-smoke-" + UUID().uuidString))
            defer { pb.releaseGlobally() }
            let engine = TextInjectionEngine(pasteboard: pb, canPaste: { true }, postPaste: {
                output = "自动输入检查：" + text; return true
            })
            if engine.inject(text, targetIsReady: { !failRecoveryTarget }) != .inserted {
                output = "目标失效，保留结果并提示手动粘贴：" + (pb.string(forType: .string) ?? "")
            }
        }
        panel.center(); recoveryPanel = panel; panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func showRecording() {
        recordingModel?.cancel()
        let reference = WeakRecordingModel()
        let vm = RecordingViewModel(snapshotProvider: {
            try AIProcessingSnapshot.capture(modes: fixture.modes, connections: fixture.connections, defaults: fixture.defaults)
        }, modeNameProvider: { fixture.modes.selected.name }, processor: service, stopCapture: {
            // Model the ASR callback explicitly, independently of whether a secondary window renders.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                reference.value?.processAndInput("合成语音：请把两个测试步骤整理清楚。")
            }
        }, cancelCapture: {})
        reference.value = vm
        vm.isRecording = true; vm.isCaptureReady = true
        vm.hasRecoverableInput = true
        vm.onRecover = { reference.value?.cancel(); showRecovery() }
        vm.statusText = "这是一段合成语音，用于验证模式切换和停止处理。"
        vm.onCancel = { output = "已取消"; showingRecording = false }
        vm.onComplete = { text, _ in output = text; showingRecording = false }
        recordingModel = vm; showingRecording = true
    }
}

private extension AIProcessingRegression {
    @MainActor
    static func outputGuardTests() -> [(String, () throws -> Void)] {
        [
            ("Structured reasoning and metadata never enter final text or logs", {
                let secret = "SYNTHETIC-PRIVATE-REASONING-DO-NOT-DELIVER"
                MockProtocol.reset([.init(json: ["choices": [["message": ["role": "assistant", "content": "请检查配置。",
                    "reasoning_content": secret, "reasoning_details": [["text": secret]], "metadata": ["internal": secret]], "finish_reason": "stop"]],
                    "usage": ["private": secret], "model": secret])])
                let f = Fixture()
                try check(try process(f.service()).get() == "请检查配置。", "Structured private fields leaked")
                try check(!f.messages.joined().contains(secret) && f.messages.contains { $0.contains("separated_reasoning=true") }, "Unsafe or missing diagnostics")
            }),
            ("Typed content accepts only final text blocks and rejects unknown shapes", {
                MockProtocol.reset([.init(json: ["choices": [["message": ["content": [
                    ["type": "thinking", "thinking": "hidden"], ["type": "reasoning", "text": "hidden"],
                    ["type": "text", "text": "请检查"], ["type": "output_text", "text": "配置。"],
                    ["type": "metadata", "text": "hidden"]]], "finish_reason": "stop"]]])])
                let f = Fixture()
                try check(try process(f.service()).get() == "请检查配置。", "Typed blocks leaked or reordered")
                for block: [String: Any] in [["type": "unknown", "text": "hidden"], ["text": "hidden"], ["type": "text", "text": ["value": "hidden"]]] {
                    MockProtocol.reset([.init(json: ["choices": [["message": ["content": [block]], "finish_reason": "stop"]]])])
                    try expectFailure(try process(f.service()), code: "parse_error")
                }
            }),
            ("Provider reasoning copied into content is rejected even without textual markers", {
                let hidden = "先分析用户提供的上下文并决定如何组织最终输出。"
                for message: [String: Any] in [
                    ["content": hidden + "\n正文", "reasoning_content": hidden],
                    ["content": hidden + "\n正文", "reasoning_details": [["text": hidden]]],
                    ["content": [["type": "reasoning", "text": hidden], ["type": "text", "text": hidden + "\n正文"]]]
                ] {
                    MockProtocol.reset([.init(json: ["choices": [["message": message, "finish_reason": "stop"]]])])
                    let f = Fixture(); try expectFailure(try process(f.service()), code: "unsafe_output")
                }
            }),
            ("Native compatibility skips reasoning messages and rejects role or channel metadata", {
                let parsed = try AIOutputGuard.responseText(["choices": [["messages": [
                    ["type": "reasoning", "text": "hidden"], ["sender_type": "BOT", "text": "正文"]]]]])
                try check(parsed.text == "正文" && parsed.discardedReasoning, "First native reasoning message leaked")
                for extra: [String: Any] in [["role": "system"], ["channel": "analysis"], ["sender_type": "user"]] {
                    var message: [String: Any] = ["content": "hidden"]
                    extra.forEach { message[$0.key] = $0.value }
                    MockProtocol.reset([.init(json: ["choices": [["message": message, "finish_reason": "stop"]]])])
                    let f = Fixture(); try expectFailure(try process(f.service()), code: "unsafe_output")
                }
                MockProtocol.reset([.init(json: ["choices": [["message": ["content": "hidden", "channel": ["analysis"]]]]])])
                let f = Fixture(); try expectFailure(try process(f.service()), code: "parse_error")
            }),
            ("Missing final content cannot fall back to reasoning or a conflicting output field", {
                let f = Fixture()
                for content: Any in [NSNull(), [["type": "reasoning", "text": "hidden"]]] {
                    MockProtocol.reset([.init(json: ["choices": [["message": ["content": content, "reasoning_content": "hidden"]]], "output": "hidden fallback"])])
                    try expectFailure(try process(f.service()), code: "empty_output")
                }
                MockProtocol.reset([.init(json: ["choices": [], "output": "hidden fallback"])])
                try expectFailure(try process(f.service()), code: "parse_error")
            }),
            ("All response paths remove repeated nested attributed reasoning tags", {
                let tagged = "<THINK phase=\"draft\">hidden<thinking>nested</thinking></THINK>\n<analysis>hidden</analysis>\n请检查配置。<reasoning>tail</reasoning>"
                for json: [String: Any] in [answer(tagged), ["choices": [["messages": [["text": tagged]]]]], ["output": tagged]] {
                    MockProtocol.reset([.init(json: json)]); let f = Fixture()
                    try check(try process(f.service()).get() == "请检查配置。", "Compatibility path bypassed guard")
                }
                for tag in ["think", "thinking", "reasoning", "reasoning_content", "analysis", "reflection", "internal_analysis", "chain_of_thought", "chain-of-thought", "metadata"] {
                    try check(try AIOutputGuard.clean("<\(tag)>hidden</\(tag)>正文") == "正文", "Tag family escaped")
                }
                try check(try AIOutputGuard.clean("<think>```html\n<reasoning>nested</reasoning>\n```</think>正文") == "正文", "Reasoning code escaped its enclosing block")
            }),
            ("Malformed reasoning delimiters reject the entire reply instead of pasting fragments", {
                for text in ["<think>hidden", "正文\n<think>hidden", "hidden</think>正文", "<think>one</analysis>正文",
                             "<think>one</think><think>two", "<think", "<analysis/>", "<think>one</think></think>正文",
                             "&lt;think&gt;hidden&lt;/think&gt;正文", "<th\u{200B}ink>hidden</think>正文"] {
                    try expectFailure(AIProcessingService.validatedOutput(text, isInstruction: true), code: "unsafe_output")
                }
            }),
            ("Reasoning headings fences and serialized protocol metadata are blocked", {
                for text in ["思考过程：\n内部草稿\n最终回复：\n正文", "## Analysis\nhidden\n## Final Answer\n正文",
                             "**Thinking Process:**\nhidden", "正文\n# 内部分析\nhidden", "```thinking\nhidden\n```\n正文",
                             "<|im_start|>assistant<|channel|>analysis\nhidden", "[THINK]hidden[/THINK]正文",
                             "{\"reasoning_content\":\"hidden\",\"content\":\"正文\"}"] {
                    try expectFailure(AIProcessingService.validatedOutput(text, isInstruction: true), code: "unsafe_output")
                }
            }),
            ("AI instruction mode blocks novel untagged model self-narration", {
                let f = Fixture()
                for text in ["我需要先分析用户的需求，然后组织指令。\n请检查配置。", "用户想要优化软件，我应该保留要求。\n请优化软件。",
                             "I need to analyze the user's request before rewriting it.\nCheck the configuration.",
                             "# **分析**\n内部草稿\n最终回复：正文", "思考：内部草稿\n正文"] {
                    MockProtocol.reset([.init(json: answer(text))])
                    try expectFailure(try process(f.service()), code: "unsafe_output")
                }
            }),
            ("Task analysis instructions source-authored phrasing and code remain intact", {
                let samples = ["请先分析问题，再列出处理步骤。", "# 问题分析\n检查日志，再修复配置。", "用户希望优化软件。",
                    "## Analysis\n这是我准备的分析结论。", "请检查 `reasoning_content` 字段，并过滤 `<think>` 标签。",
                    "```html\n<think>literal markup</think>\n```", "~~~json\n{\"analysis\":\"业务分析\",\"metadata\":{}}\n~~~",
                    "# 方案\n\n1. 分析需求。\n2. 给出结论。\n\nＡＢＣ"]
                for text in samples {
                    let policy = AIOutputPolicy(stripWrappers: false, isInstruction: true, originalText: text)
                    try check(try AIOutputGuard.clean(text, policy: policy) == text, "Legitimate task content changed")
                }
                let json = "{\"analysis\":\"业务结论\",\"metadata\":{\"source\":\"用户\"}}"
                try check(try AIOutputGuard.clean(json, policy: AIOutputPolicy(stripWrappers: false)) == json, "Task JSON confused with an API envelope")
                let customAnalysis = "## Analysis\nThis is the requested business conclusion."
                try check(try AIOutputGuard.clean(customAnalysis, policy: AIOutputPolicy(stripWrappers: false)) == customAnalysis, "Custom analysis conclusion was blocked")
            }),
            ("Final envelopes are strict and output validation is idempotent", {
                for text in ["<think>hidden</think><final>正文</final>", "<answer>正文</answer>", "正文"] {
                    let once = try AIOutputGuard.clean(text)
                    try check(once == "正文" && (try AIOutputGuard.clean(once)) == once, "Repeated guard changed content")
                }
                try check(try AIOutputGuard.clean("根据语音内容整理如下：\n正文", policy: AIOutputPolicy(stripWrappers: true)) == "正文", "Transcript wrapper survived")
                try check(try AIOutputGuard.clean("根据语音内容整理如下：\n正文", policy: AIOutputPolicy(stripWrappers: false)) == "根据语音内容整理如下：\n正文", "Custom prefix stripped")
                for text in ["<final>正文", "<final>正文</final>hidden", "hidden<final>正文</final>", "<final>正文</final><final>other</final>"] {
                    try expectFailure(AIProcessingService.validatedOutput(text), code: "unsafe_output")
                }
            }),
            ("Nonempty tool calls are rejected even when the provider claims stop", {
                for calls: [String: Any] in [["tool_calls": [["function": ["name": "hidden"]]]], ["function_call": ["name": "hidden"]]] {
                    var message: [String: Any] = ["content": "partial"]
                    calls.forEach { message[$0.key] = $0.value }
                    MockProtocol.reset([.init(json: ["choices": [["message": message, "finish_reason": "stop"]]])])
                    let f = Fixture(); try expectFailure(try process(f.service()), code: "incomplete_output")
                }
            }),
            ("Paste boundary revalidates successful results and retains the original on suspicion", {
                let mode = ModeDefinition.preset(.aiInstruction)
                let snapshot = AIProcessingSnapshot(mode: mode, language: .original, systemPrompt: "old saved prompt", connection: .preset(.qwen), apiKey: "synthetic")
                let vm = RecordingViewModel(snapshotProvider: { snapshot }, modeNameProvider: { mode.name }, stopCapture: {}, cancelCapture: {})
                vm.isRecording = true; vm.stopRecording()
                var outputs: [String] = []; vm.onComplete = { text, _ in outputs.append(text) }
                for suspect in ["正文<think>unfinished", "我需要先分析用户的需求。", "# 思考过程\nhidden"] {
                    vm.finishAIProcessing(.success(suspect), originalText: input)
                    try check(outputs.last == input && vm.fallbackNotice == MiniMaxError.fallbackNotice(for: MiniMaxError.unsafeOutput), "Unsafe success reached paste")
                }
                vm.finishAIProcessing(.success("<think>hidden</think>正文"), originalText: input)
                try check(outputs.last == "正文" && vm.fallbackNotice == nil, "Clean final response failed boundary guard")
                vm.cancel(); let count = outputs.count
                vm.finishAIProcessing(.success("<think>hidden</think>正文"), originalText: input)
                try check(outputs.count == count, "Cancelled output escaped guard")
            }),
            ("Runtime output contract applies to saved prompts without overwriting user rules", {
                let c = ConfigurationFixture()
                var mode = ModeDefinition.preset(.aiInstruction); mode.sceneRules = "old saved scene"
                try c.modes.save(mode, baseRules: "old saved base"); try c.modes.select(mode.id)
                _ = try c.connections.save(.preset(.qwen), key: "synthetic")
                let snapshot = try AIProcessingSnapshot.capture(modes: c.modes, connections: c.connections, defaults: c.defaults)
                try check(snapshot.systemPrompt.hasSuffix(PromptComposer.outputContract) && snapshot.systemPrompt.contains("old saved scene"), "Existing prompt missed contract")
                try check(c.modes.configuration.baseRules == "old saved base" && c.modes.selected.sceneRules == "old saved scene", "Contract rewrote user settings")
                let f = Fixture(); MockProtocol.reset([.init(json: answer("正文"))])
                _ = try process(f.service())
                let messages = try body()["messages"] as! [[String: String]]
                try check(messages[0]["role"] == "system" && messages[0]["content"] == PromptComposer.outputContract, "Legacy request missed system contract")
            }),
            ("Recording pipeline rejects contaminated final responses and preserves custom code end to end", {
                let customCode = "```html\n<think>literal markup</think>\n```"
                for (mode, response, expected, shouldWarn) in [
                    (ModeDefinition.preset(.aiInstruction), "我需要先分析用户的需求。\n请检查配置。", input, true),
                    (ModeDefinition(id: UUID().uuidString, name: "代码生成", sceneRules: "生成代码"),
                     "<think>hidden</think>\n" + customCode, customCode, false)
                ] {
                    let f = Fixture(); let service = f.service()
                    let snapshot = AIProcessingSnapshot(mode: mode, language: .original, systemPrompt: "saved scene", connection: .preset(.qwen), apiKey: "synthetic")
                    let vm = RecordingViewModel(snapshotProvider: { snapshot }, modeNameProvider: { mode.name }, processor: service, stopCapture: {}, cancelCapture: {})
                    var output: String?; vm.onComplete = { text, _ in output = text }
                    vm.isRecording = true; vm.stopRecording()
                    MockProtocol.reset([.init(json: answer(response), delay: 0.03)])
                    vm.processAndInput(input); spin(2, until: { output != nil })
                    try check(output == expected && (vm.fallbackNotice != nil) == shouldWarn, "Service-to-paste guard failed")
                    try check(MockProtocol.requests.count == 1, "Output guard generated extra requests")
                    let sent = try body()["messages"] as! [[String: String]]
                    try check(sent[0]["content"]!.hasSuffix(PromptComposer.outputContract), "Production snapshot missed contract")
                }
            }),
            ("Unsafe replies do not trigger another model call and diagnostics omit their content", {
                let hidden = "SYNTHETIC-PRIVATE-CONTENT"
                let f = Fixture(); MockProtocol.reset([.init(json: answer("<think>" + hidden))])
                try expectFailure(try process(f.service()), code: "unsafe_output")
                spin(1.1)
                try check(MockProtocol.requests.count == 1 && f.messages.contains { $0.contains("outcome=unsafe_output") }, "Unsafe reply retried or lacks diagnostic")
                try check(!f.messages.joined().contains(hidden), "Diagnostics exposed private content")
            }),
            ("Output guard handles long mixed-language input and repeated reasoning blocks", {
                let body = String(repeating: "请检查 API 配置与条件，保留确定程度。\n", count: 2000).trimmingCharacters(in: .whitespacesAndNewlines)
                let text = String(repeating: "<think>hidden</think>", count: 1000) + body
                try check(try AIOutputGuard.clean(text, policy: AIOutputPolicy(stripWrappers: false)) == body, "Long response lost body or leaked reasoning")
            })
        ]
    }
}


@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    var occupied = Set<HotKeyConfiguration>()
    var systemOccupied = Set<HotKeyConfiguration>()
    var registrations: [UInt32: HotKeyConfiguration] = [:]
    var registerCalls = 0
    var checks = 0
    var down = false
    var failure: Error?
    var onRegister: ((UInt32) -> Void)?
    func checkSystem(_ configuration: HotKeyConfiguration) throws {
        checks += 1
        if systemOccupied.contains(configuration) { throw HotKeyFailure.occupied }
    }
    func register(_ configuration: HotKeyConfiguration, id: UInt32) throws {
        registerCalls += 1
        if let failure { throw failure }
        if occupied.contains(configuration) { throw HotKeyFailure.occupied }
        if registrations.values.contains(configuration) { throw HotKeyFailure.system("重复注册", -1) }
        registrations[id] = configuration
        onRegister?(id)
    }
    func unregister(_ id: UInt32) { registrations.removeValue(forKey: id) }
    func isKeyDown(_ keyCode: UInt32) -> Bool { down }
    func shutdown() { registrations.removeAll() }
    func press() { if let id = registrations.keys.first { onEvent?(id, true) } }
    func release() { if let id = registrations.keys.first { onEvent?(id, false) } }
}

@MainActor
private extension AIProcessingRegression {
    static func hotkeyTests() -> [(String, () throws -> Void)] {
        let custom = HotKeyConfiguration(keyCode: 40, modifiers: UInt32(controlKey | optionKey))
        let alternate = HotKeyConfiguration(keyCode: 90, modifiers: UInt32(cmdKey | controlKey | optionKey))
        return [
            ("Hotkey: default validates and uses physical codes", {
                try HotKeyConfiguration.standard.validateSpokenCommands()
                try custom.validateSpokenCommands(); try alternate.validateSpokenCommands()
                try check(HotKeyConfiguration.standard.displayName == "⌥ 空格", "Wrong default label")
                try check(custom.accessibilityName.contains("控制键") && custom.accessibilityName.contains("选项键"), "Missing Chinese accessibility name")
                try check(HotKeyConfiguration.modifiers(from: [.command, .shift, .capsLock, .function]) == UInt32(cmdKey | shiftKey), "Unexpected persisted modifiers")
            }),
            ("Hotkey: bare, Shift-only, Esc, modifiers, Fn and unknown keys rejected", {
                for candidate in [HotKeyConfiguration(keyCode: 0, modifiers: 0),
                    HotKeyConfiguration(keyCode: 0, modifiers: UInt32(shiftKey)),
                    HotKeyConfiguration(keyCode: 53, modifiers: UInt32(cmdKey)),
                    HotKeyConfiguration(keyCode: 58, modifiers: UInt32(optionKey)),
                    HotKeyConfiguration(keyCode: 63, modifiers: UInt32(optionKey)),
                    HotKeyConfiguration(keyCode: 300, modifiers: UInt32(cmdKey)),
                    HotKeyConfiguration(version: 2, keyCode: 49, modifiers: UInt32(optionKey))] {
                    try mustThrow { try candidate.validate() }
                }
            }),
            ("Hotkey: Spoken save and window commands rejected", {
                for code: UInt32 in [1, 12, 13, 43, 8, 9] {
                    try mustThrow { try HotKeyConfiguration(keyCode: code, modifiers: UInt32(cmdKey)).validateSpokenCommands() }
                }
            }),
            ("Hotkey: first launch occupied default is unavailable, preserved and not auto-replaced", {
                let f = ConfigurationFixture(); f.hotkeyRegistrar.occupied.insert(.standard)
                let h = f.hotkeys
                try check(h.configuration == .standard && h.warning != nil && !h.isRegistered && !h.showsGuide, "Occupied default marked usable")
                try check(f.hotkeyRegistrar.registrations.isEmpty, "Occupied default registered")
                try check(!FileManager.default.fileExists(atPath: f.file("hotkey-v1").url.path), "Startup wrote configuration")
            }),
            ("Hotkey: system enabled shortcut rejected before Carbon registration", {
                let f = ConfigurationFixture(); f.hotkeyRegistrar.systemOccupied.insert(.standard)
                try check(f.hotkeys.warning != nil && f.hotkeyRegistrar.registerCalls == 0, "System conflict skipped")
            }),
            ("Hotkey: saved custom remains selected on occupied restart", {
                let f = ConfigurationFixture(); try f.file("hotkey-v1").save(custom)
                f.hotkeyRegistrar.occupied.insert(custom)
                try check(f.hotkeys.configuration == custom && !f.hotkeys.isRegistered, "Custom silently reverted")
                try check(try f.file("hotkey-v1").read(HotKeyConfiguration.self) == custom, "Saved shortcut changed")
            }),
            ("Hotkey: occupied new candidate keeps working key and draft", {
                let f = ConfigurationFixture(); let h = f.hotkeys; let editor = HotKeyEditor(service: h)
                editor.capture(custom); f.hotkeyRegistrar.occupied.insert(custom)
                try mustThrow { try editor.save() }
                try check(h.isRegistered && h.configuration == .standard && editor.draft == custom && editor.isDirty, "Failed candidate replaced working key or draft")
                try check(f.hotkeyRegistrar.registrations.count == 1, "Registration leaked")
                var triggered = 0; h.onTriggered = { triggered += 1 }; f.hotkeyRegistrar.press()
                try check(triggered == 1, "Old shortcut stopped working")
            }),
            ("Hotkey: restoring an occupied default preserves the custom key", {
                let f = ConfigurationFixture(); let h = f.hotkeys; try h.save(custom)
                f.hotkeyRegistrar.occupied.insert(.standard)
                let editor = HotKeyEditor(service: h); editor.restoreDefault()
                try check(h.configuration == custom && h.isRegistered && editor.draft == .standard && editor.error != nil, "Default bypassed conflict checks")
                try check(try f.file("hotkey-v1").read(HotKeyConfiguration.self) == custom, "Default overwrote persisted custom")
            }),
            ("Hotkey: atomic save failure rolls back temporary registration", {
                let f = ConfigurationFixture(); let h = f.hotkeys; try h.save(custom)
                f.failingFiles.insert("hotkey-v1")
                try mustThrow { try h.save(alternate) }
                try check(h.configuration == custom && h.isRegistered && Array(f.hotkeyRegistrar.registrations.values) == [custom], "Disk failure damaged working state")
                try check(try f.file("hotkey-v1").read(HotKeyConfiguration.self) == custom, "Disk failure damaged file")
            }),
            ("Hotkey: successful switch persists and old/staged events cannot trigger", {
                let f = ConfigurationFixture(); let h = f.hotkeys
                let oldID = f.hotkeyRegistrar.registrations.keys.first!
                var triggered = 0; h.onTriggered = { triggered += 1 }
                f.hotkeyRegistrar.onRegister = { id in f.hotkeyRegistrar.onEvent?(id, true) }
                try h.save(custom)
                f.hotkeyRegistrar.onRegister = nil
                f.hotkeyRegistrar.onEvent?(oldID, true)
                try check(triggered == 0 && h.isRegistered && f.hotkeyRegistrar.registrations.count == 1, "Staged or old event triggered")
                f.hotkeyRegistrar.press(); try check(triggered == 1, "New shortcut did not trigger")
                let restarted = HotKeyService(file: f.file("hotkey-v1"), registrar: FakeHotKeyRegistrar(), defaults: f.defaults)
                restarted.registerAll(); try check(restarted.configuration == custom && restarted.isRegistered, "Restart lost saved shortcut")
            }),
            ("Hotkey: same combination and repeated start do not register twice", {
                let f = ConfigurationFixture(); let h = f.hotkeys
                h.registerAll(); try h.save(.standard); try h.save(.standard)
                try check(f.hotkeyRegistrar.registerCalls == 1 && f.hotkeyRegistrar.registrations.count == 1, "Duplicate registration")
            }),
            ("Hotkey: wake failure changes status and retry clears warning", {
                let f = ConfigurationFixture(); let h = f.hotkeys; var notices = 0
                h.onUnavailable = { notices += 1 }
                f.hotkeyRegistrar.occupied.insert(.standard); h.handleWake(); h.handleWake()
                try check(h.warning != nil && !h.isRegistered && notices == 1, "Wake failure or duplicate notices")
                f.hotkeyRegistrar.occupied.removeAll(); h.recheck()
                try check(h.isRegistered && h.warning == nil && h.configuration == .standard, "Retry did not recover")
            }),
            ("Hotkey: capture suspends own registration and resumes", {
                let f = ConfigurationFixture(); let h = f.hotkeys; let id = f.hotkeyRegistrar.registrations.keys.first!
                var triggered = 0; h.onTriggered = { triggered += 1 }
                try h.beginCapture(); try h.beginCapture(); f.hotkeyRegistrar.onEvent?(id, true)
                try check(h.isCapturing && h.state == .paused && f.hotkeyRegistrar.registrations.isEmpty && triggered == 0, "Capture fired recording")
                h.handleWake(); try check(h.state == .paused, "Wake reenabled capture")
                h.endCapture(); h.endCapture()
                try check(h.isRegistered && f.hotkeyRegistrar.registrations.count == 1, "Capture did not restore")
            }),
            ("Hotkey: capture restore failure is unavailable, not enabled", {
                let f = ConfigurationFixture(); let h = f.hotkeys; try h.beginCapture()
                f.hotkeyRegistrar.occupied.insert(.standard); h.endCapture()
                try check(!h.isCapturing && !h.isRegistered && h.warning != nil, "Resume failure hidden")
                f.hotkeyRegistrar.occupied.removeAll(); h.recheck(); try check(h.isRegistered, "Resume retry failed")
            }),
            ("Hotkey: busy prohibits save, capture and restore-default", {
                let f = ConfigurationFixture(); let h = f.hotkeys; try h.save(custom); h.setBusy(true)
                try mustThrow { try h.save(alternate) }; try mustThrow { try h.beginCapture() }
                let editor = HotKeyEditor(service: h); editor.restoreDefault()
                try check(h.configuration == custom && editor.error != nil && h.isRegistered, "Busy edit allowed")
                h.setBusy(false); try h.save(alternate); try check(h.configuration == alternate, "Busy lock never released")
            }),
            ("Hotkey: key hold deduplicates while repeated presses still trigger", {
                let f = ConfigurationFixture(); let h = f.hotkeys; var triggered = 0; h.onTriggered = { triggered += 1 }
                for _ in 0..<10 { f.hotkeyRegistrar.press() }
                try check(triggered == 1, "Hold repeated")
                f.hotkeyRegistrar.release(); f.hotkeyRegistrar.press()
                try check(triggered == 2, "Second press lost")
            }),
            ("Hotkey: a key already held on resume waits for release", {
                let f = ConfigurationFixture(); let h = f.hotkeys; var triggered = 0; h.onTriggered = { triggered += 1 }
                try h.beginCapture(); f.hotkeyRegistrar.down = true; h.endCapture(); f.hotkeyRegistrar.press()
                try check(triggered == 0, "Captured held key activated recording")
                f.hotkeyRegistrar.release(); f.hotkeyRegistrar.press(); try check(triggered == 1, "Release did not rearm")
            }),
            ("Hotkey: corrupt configuration stays untouched until a successful save", {
                let f = ConfigurationFixture(); try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
                let bytes = Data("invalid-config".utf8); try bytes.write(to: f.file("hotkey-v1").url)
                let h = f.hotkeys
                try check(h.warning != nil && !h.isRegistered && (try Data(contentsOf: f.file("hotkey-v1").url)) == bytes, "Corrupt config silently replaced")
                try h.save(custom); try check(h.isRegistered && h.configuration == custom, "Could not repair config")
            }),
            ("Hotkey: registration error code is visible and leaves old key", {
                let f = ConfigurationFixture(); let h = f.hotkeys
                f.hotkeyRegistrar.failure = HotKeyFailure.system("注册", -9876)
                try mustThrow { try h.save(custom) }
                try check(h.isRegistered && h.configuration == .standard, "API failure replaced active key")
                h.handleWake(); try check(h.warning?.contains("-9876") == true, "API error hidden")
            }),
            ("Hotkey: one-time guide acknowledges explicitly and yields to conflict", {
                let f = ConfigurationFixture(); let h = f.hotkeys
                try check(h.showsGuide, "New guide missing")
                try h.beginCapture(); try check(!h.showsGuide, "Guide shown during capture"); h.endCapture()
                h.acknowledgeGuide(); try check(!h.showsGuide, "Guide acknowledgment failed")
                let restarted = HotKeyService(file: f.file("hotkey-v1"), registrar: FakeHotKeyRegistrar(), defaults: f.defaults)
                restarted.registerAll(); try check(!restarted.showsGuide, "Guide repeated after restart")
            }),
            ("Hotkey: navigation stops capture even when user cancels leaving", {
                let f = ConfigurationFixture(); let h = f.hotkeys; let editor = HotKeyEditor(service: h)
                editor.capture(custom); try h.beginCapture()
                let guarder = SettingsNavigationGuard(decision: { .cancel }, reportFailure: { _ in })
                guarder.install(isDirty: { editor.isDirty }, save: editor.save, discard: editor.discard, prepareNavigation: editor.finishCapture)
                try check(!guarder.allowNavigation() && !h.isCapturing && h.isRegistered && editor.isDirty, "Navigation cancel left hotkey paused or lost draft")
            }),
            ("Hotkey: recorder accepts on key-up without starting recording", {
                let f = ConfigurationFixture(); let h = f.hotkeys; let capture = HotKeyCaptureSession(service: h)
                var result: HotKeyConfiguration?; var triggers = 0
                h.onTriggered = { triggers += 1 }; capture.onCaptured = { result = $0 }
                try capture.begin()
                capture.consume(keyCode: custom.keyCode, flags: [.control, .option], down: true)
                try check(result == nil && h.isCapturing && !h.isRegistered, "Accepted before key release")
                capture.consume(keyCode: custom.keyCode, flags: [.control, .option], down: true, isRepeat: true)
                capture.consume(keyCode: custom.keyCode, flags: [], down: false)
                try check(result == custom && !capture.active && h.isRegistered && triggers == 0, "Capture key-up failed or started recording")
            }),
            ("Hotkey: Esc cancels pending candidate and restores", {
                let f = ConfigurationFixture(); let capture = HotKeyCaptureSession(service: f.hotkeys)
                var result: HotKeyConfiguration?; capture.onCaptured = { result = $0 }
                try capture.begin(); capture.consume(keyCode: custom.keyCode, flags: [.control, .option], down: true)
                capture.consume(keyCode: 53, flags: [], down: true)
                try check(result == nil && !capture.active && f.hotkeys.isRegistered, "Esc saved a candidate or failed to restore")
            }),
            ("Hotkey: invalid and Spoken command keys stay in capture", {
                let f = ConfigurationFixture(); let capture = HotKeyCaptureSession(service: f.hotkeys)
                var errors = 0; capture.onError = { _ in errors += 1 }; try capture.begin()
                capture.consume(keyCode: 1, flags: [.command], down: true)
                capture.consume(keyCode: 1, flags: [], down: true)
                try check(errors == 2 && capture.pending == nil && capture.active && !f.hotkeys.isRegistered, "Invalid key escaped recorder")
                capture.finish(); try check(f.hotkeys.isRegistered, "Blur/close did not restore")
            }),
            ("Hotkey: shutdown clears registration and ignores stale events", {
                let f = ConfigurationFixture(); let h = f.hotkeys; let id = f.hotkeyRegistrar.registrations.keys.first!
                var triggered = 0; h.onTriggered = { triggered += 1 }; h.unregisterAll()
                f.hotkeyRegistrar.onEvent?(id, true); h.handleWake()
                try check(triggered == 0 && f.hotkeyRegistrar.registrations.isEmpty && !h.isRegistered, "Shutdown leaked registration")
            })
        ]
    }
}

@MainActor
private extension AIProcessingRegression {
    static func accessibilityTests() -> [(String, () throws -> Void)] {
        [
            ("Accessibility: startup guide is shown only for missing permission", {
                let f = ConfigurationFixture(); f.permissionState = .notAuthorized
                try check(f.accessibility.needsInitialGuide && f.accessibility.needsAttention, "Denied startup hidden")
                f.permissionState = .ready; f.accessibility.refresh()
                try check(!f.accessibility.needsInitialGuide && !f.accessibility.needsAttention, "Granted startup warned")
            }),
            ("Accessibility: skipping guide survives restart without hiding permission warning", {
                let f = ConfigurationFixture(); f.permissionState = .notAuthorized
                f.accessibility.markGuidePresented()
                let restarted = AccessibilityPermissionService(defaults: f.defaults, readPermission: { .notAuthorized }, openSettings: { true })
                try check(!restarted.needsInitialGuide && restarted.needsAttention, "Skip suppressed warning or repeated guide")
            }),
            ("Accessibility: opening settings never marks authorization as granted", {
                let f = ConfigurationFixture(); f.permissionState = .notAuthorized
                f.accessibility.openSettings()
                try check(f.settingsOpenCount == 1 && !f.accessibility.canAutoPaste, "Opening settings inferred grant")
                f.accessibility.recheck()
                try check(f.accessibility.feedback?.contains("尚未") == true, "Recheck concealed missing permission")
            }),
            ("Accessibility: failed system settings open provides manual route", {
                let f = ConfigurationFixture(); f.permissionState = .notAuthorized; f.settingsOpenSucceeds = false
                f.accessibility.openSettings()
                try check(f.accessibility.feedback?.contains("隐私与安全性") == true && f.accessibility.needsAttention, "Missing settings failure path")
            }),
            ("Accessibility: grant then revocation updates live state and clears stale feedback", {
                let f = ConfigurationFixture(); f.permissionState = .notAuthorized
                f.accessibility.recheck(); f.permissionState = .ready
                try check(f.accessibility.refresh() && f.accessibility.feedback == nil, "Grant not recognized")
                f.permissionState = .notAuthorized
                try check(!f.accessibility.refresh() && f.accessibility.needsAttention, "Revocation not recognized")
            }),
            ("Accessibility: AX trust without event posting access is not ready", {
                let f = ConfigurationFixture(); f.permissionState = .eventPostingDenied
                try check(!f.accessibility.canAutoPaste && f.accessibility.state.statusText.contains("尚未生效"), "Partial authorization marked ready")
            }),
            ("Accessibility: settings polling is bounded and guide visibility balances", {
                let f = ConfigurationFixture(); var date = Date(timeIntervalSince1970: 100)
                let service = AccessibilityPermissionService(defaults: f.defaults, readPermission: { .notAuthorized }, openSettings: { true }, now: { date })
                try check(!service.shouldPoll, "Background polling unbounded")
                service.openSettings(); try check(service.shouldPoll, "Not polling after settings opened")
                date = date.addingTimeInterval(121); try check(!service.shouldPoll, "Polling did not expire")
                service.guideAppeared(); service.guideAppeared(); service.guideDisappeared()
                try check(service.shouldPoll, "Second guide lost monitoring")
                service.guideDisappeared(); service.guideDisappeared()
                try check(!service.shouldPoll, "Dismissed guide keeps polling")
            }),
            ("Accessibility: current application reveal only runs on user action", {
                let f = ConfigurationFixture(); var reveals = 0
                let service = AccessibilityPermissionService(defaults: f.defaults, readPermission: { .ready }, openSettings: { true }, revealApplication: { reveals += 1 })
                service.refresh(); try check(reveals == 0, "Finder opened implicitly")
                service.revealApplication(); try check(reveals == 1, "Reveal action missing")
            }),
            ("Accessibility: all view roots use injected status without touching TCC", {
                let f = ConfigurationFixture(); f.permissionState = .notAuthorized
                let menu = ContentView(onOpenSettings: { _ in }, modes: f.modes, connections: f.connections, speechConnections: f.speechConnections, hotkeys: f.hotkeys, accessibility: f.accessibility, defaults: f.defaults)
                let settings = SettingsView(modes: f.modes, connections: f.connections, hotkeys: f.hotkeys, accessibility: f.accessibility, initialSection: .permissions, defaults: f.defaults, speechDependencies: f.speechSettings)
                let vm = RecordingViewModel(snapshotProvider: { throw TestFailure(description: "Unused") }, modeNameProvider: { "测试" }, stopCapture: {}, cancelCapture: {})
                let panel = RecordingPanelView(viewModel: vm, modes: f.modes, hotkeys: f.hotkeys, accessibility: f.accessibility)
                try check(menu.accessibility === f.accessibility && settings.accessibility === f.accessibility && panel.accessibility === f.accessibility, "Permission singleton leaked into fake UI")
            }),
            ("Injection: missing permission keeps result for manual paste without AX or events", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                pb.setString("old clipboard", forType: .string)
                var posts = 0; var prepares = 0
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { false }, postPaste: { posts += 1; return true }, prepareTarget: { prepares += 1 })
                try check(engine.inject("synthetic result") == .permissionRequired, "Permission failure not distinguished")
                engine.finishClipboardRestore()
                try check(pb.string(forType: .string) == "synthetic result" && posts == 0 && prepares == 0, "Fallback was lost or automation attempted")
            }),
            ("Injection: permission revoked during target preparation prevents paste", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                var granted = true; var posts = 0
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { granted }, postPaste: { posts += 1; return true }, prepareTarget: { granted = false })
                try check(engine.inject("synthetic result") == .permissionRequired && posts == 0, "Revocation bypassed final check")
                try check(pb.string(forType: .string) == "synthetic result", "Result missing")
            }),
            ("Injection: recovery validates the target after preparation and retains fallback text", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                var targetReady = true, invalidateDuringPrepare = true, posts = 0
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { true }, postPaste: { posts += 1; return true },
                    prepareTarget: { if invalidateDuringPrepare { targetReady = false } })
                try check(engine.inject("recovered result", targetIsReady: { targetReady }) == .copiedToClipboard,
                          "Changed or missing target was reported as inserted")
                engine.finishClipboardRestore()
                try check(posts == 0 && pb.string(forType: .string) == "recovered result" && engine.pendingRestoreID == nil,
                          "Stale target received paste or lost manual fallback")
                invalidateDuringPrepare = false; targetReady = true
                try check(engine.inject("next recovered result", targetIsReady: { targetReady }) == .inserted && posts == 1,
                          "Confirmed target did not receive exactly one paste")
            }),
            ("Injection: failed event creation keeps clipboard and does not report sent", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { true }, postPaste: { false })
                try check(engine.inject("synthetic result") == .copiedToClipboard, "Failed post marked inserted")
                engine.finishClipboardRestore()
                try check(pb.string(forType: .string) == "synthetic result", "Failed post result restored away")
            }),
            ("Injection: clipboard failure stops before permission or paste and supports retry", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                var writes = 0; var checks = 0; var posts = 0
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { checks += 1; return true }, postPaste: { posts += 1; return true }, writeText: { text in
                    writes += 1; return writes > 1 ? pb.setString(text, forType: .string) : false
                })
                try check(engine.inject("synthetic result") == .clipboardFailed && checks == 0 && posts == 0, "False copy success")
                try check(engine.inject("synthetic result") == .inserted && posts == 1, "Retry cannot deliver")
            }),
            ("Injection: authorized paste restores clipboard only if unchanged", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                pb.setString("old clipboard", forType: .string)
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { true }, postPaste: { true })
                try check(engine.inject("synthetic result") == .inserted, "Authorized paste failed")
                engine.finishClipboardRestore()
                try check(pb.string(forType: .string) == "old clipboard", "Old clipboard not restored")
                _ = engine.inject("another result"); pb.clearContents(); pb.setString("user copied", forType: .string)
                engine.finishClipboardRestore()
                try check(pb.string(forType: .string) == "user copied", "User clipboard overwritten")
            }),
            ("Injection: old restore callback cannot consume next delivery or missing-permission fallback", {
                let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
                var granted = true
                let engine = TextInjectionEngine(pasteboard: pb, canPaste: { granted }, postPaste: { true })
                _ = engine.inject("first")
                guard let oldID = engine.pendingRestoreID else {
                    throw TestFailure(description: "Named clipboard is unavailable; run in a macOS graphical session with pasteboard service access")
                }
                _ = engine.inject("second"); engine.finishClipboardRestore(expectedID: oldID)
                try check(pb.string(forType: .string) == "second" && engine.pendingRestoreID != nil, "Stale callback restored next output")
                granted = false; _ = engine.inject("manual result"); engine.finishClipboardRestore(expectedID: oldID)
                try check(pb.string(forType: .string) == "manual result", "Fallback lost after previous success")
            })
        ]
    }
}

private final class FakeSpeechSocket: SpeechSocket {
    private let lock = NSLock()
    private var received: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var backlog: [URLSessionWebSocketTask.Message] = []
    private var frames: [URLSessionWebSocketTask.Message] = []
    private(set) var request: URLRequest?
    private(set) var closed = false
    var openFailure = false
    var sendFailure = false
    var onSend: ((URLSessionWebSocketTask.Message) -> Void)?
    var messages: [URLSessionWebSocketTask.Message] { lock.lock(); defer { lock.unlock() }; return frames }
    func open(_ request: URLRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        self.request = request; closed = false
        completion(openFailure ? .failure(CloudSpeechError.connectionFailed) : .success(()))
    }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        lock.lock(); frames.append(message); lock.unlock()
        completion(sendFailure ? CloudSpeechError.connectionFailed : nil)
        onSend?(message)
    }
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.lock()
        if backlog.isEmpty { received = completion; lock.unlock() }
        else { let message = backlog.removeFirst(); lock.unlock(); completion(.success(message)) }
    }
    func emit(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        if let callback = received { received = nil; lock.unlock(); callback(.success(message)) }
        else { backlog.append(message); lock.unlock() }
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
}

private final class FakeCloudSpeechProvider: CloudSpeechProvider {
    let providerId: String
    let displayName = "synthetic ASR"
    var connectionState: CloudConnectionState = .idle
    var onConnectionStateChanged: ((CloudConnectionState) -> Void)?
    var isReady: Bool { connectionState == .connected }
    var partial: ((String) -> Void)?
    var final: ((String) -> Void)?
    var error: ((Error) -> Void)?
    var preconnectCount = 0
    var disconnected = false
    init(_ id: String) { providerId = id }
    func connect(apiKey: String?, model: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        partial = onPartial; final = onFinal; error = onError; connectionState = .connected; onConnectionStateChanged?(.connected)
    }
    func sendAudio(_ data: Data) {}
    func finish(completion: @escaping (String?) -> Void) { completion("synthetic final") }
    func disconnect() { disconnected = true }
    func preconnect() { preconnectCount += 1 }
    func cancelPreconnect() {}
}

extension AIProcessingRegression {
    static func speechSample(_ vendor: SpeechVendor = .qwen) -> SpeechSessionSnapshot {
        var c = SpeechConnection.preset(vendor)
        if vendor == .iflytek { c.appID = "test-app" }
        if vendor == .custom { c.endpoint = "https://asr.example.test/audio/transcriptions"; c.model = "whisper-compatible" }
        return SpeechSessionSnapshot(connection: c, credentials: SpeechCredentials(apiKey: "test-key", apiSecret: vendor == .iflytek ? "test-secret" : ""))
    }
    static func speechMessage(_ object: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        .string(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    static func iflyResult(_ id: Int, text: String, stable: Bool = false, final: Bool = false) throws -> URLSessionWebSocketTask.Message {
        try speechMessage(["msg_type": "result", "res_type": "asr", "data": ["seg_id": id, "ls": final,
            "cn": ["st": ["type": stable ? "0" : "1", "rt": [["ws": [["cw": [["w": text]]]]]]]]]])
    }
    static func volcResult(_ text: String, final: Bool = false) throws -> URLSessionWebSocketTask.Message {
        .data(SpeechWireProtocol.volcFrame(type: 9, flags: final ? 2 : 0, serialization: 1,
            payload: try JSONSerialization.data(withJSONObject: ["result": ["text": text]])))
    }
    @MainActor
    static func speechProviderTests() -> [(String, () throws -> Void)] {
        [
            ("ASR: legacy migration preserves model, workspace, engine and isolated credential once", {
                let f = ConfigurationFixture(["cloud_speech_provider": "qwen-realtime", "speech_model_name": "existing-model", "speech_workspace_id": "workspace-123", "speechRecognitionProvider": SpeechRecognitionProvider.auto.rawValue])
                f.keys.legacy = "legacy-speech-key"
                let store = f.speechConnections
                let first = try store.snapshot()
                try check(first.connection.model == "existing-model" && first.connection.endpoint.contains("workspace-123.cn-beijing.maas.aliyuncs.com"), "Legacy endpoint or model reset")
                try check(store.engine == .auto && first.credentials.apiKey == "legacy-speech-key", "Legacy key or engine lost")
                let ids = Set(f.keys.values.keys); store.reload()
                try check(Set(f.keys.values.keys) == ids && store.active?.id == first.connection.id, "Migration ran twice")
                let disk = try String(contentsOf: f.file("speech-connections").url, encoding: .utf8)
                try check(!disk.contains("legacy-speech-key") && !disk.contains("apiSecret"), "Secret written into JSON")
            }),
            ("ASR: failed migration leaves legacy settings and no staged key", {
                let f = ConfigurationFixture(["speech_model_name": "old-model"]); f.keys.legacy = "old-key"; f.failingFiles.insert("speech-connections")
                try check(f.speechConnections.loadError != nil && f.keys.values.isEmpty, "Migration failure leaked staged credential")
                try check(f.defaults.string(forKey: "speech_model_name") == "old-model" && f.keys.legacy == "old-key", "Legacy was overwritten")
                f.failingFiles.removeAll(); f.speechConnections.reload()
                try check(f.speechConnections.active?.model == "old-model", "Recovery failed")
            }),
            ("ASR: launch never prompts for legacy credentials and explicit retry completes migration", {
                let f = ConfigurationFixture(["speech_model_name": "old-model"])
                f.keys.legacy = "private-legacy"; f.keys.legacyRequiresInteraction = true
                let store = f.speechConnections
                try check(store.loadError != nil && f.keys.reads == 0 && f.keys.noninteractiveLegacyReads == 1, "Startup attempted interactive credential access")
                try check(!FileManager.default.fileExists(atPath: f.file("speech-connections").url.path) && f.keys.values.isEmpty, "Blocked migration changed saved state")
                store.reload(allowCredentialPrompt: true)
                try check(store.loadError == nil && (try store.snapshot()).credentials.apiKey == "private-legacy", "Explicit migration retry lost legacy key")
                let reads = f.keys.reads; store.reload()
                try check(f.keys.reads == reads, "Completed migration read legacy key again")
            }),
            ("ASR: denied migration retry keeps old settings and remains retryable", {
                let f = ConfigurationFixture(["speech_model_name": "old-model"])
                f.keys.legacy = "private-legacy"; f.keys.failRead = true
                let store = f.speechConnections; store.reload(allowCredentialPrompt: true)
                try check(store.loadError != nil && store.active == nil && f.keys.values.isEmpty, "Denied migration published partial configuration")
                try check(f.keys.legacy == "private-legacy" && f.defaults.string(forKey: "speech_model_name") == "old-model", "Denied migration changed legacy settings")
                f.keys.failRead = false; store.reload(allowCredentialPrompt: true)
                try check(store.loadError == nil && store.active?.model == "old-model", "Retry did not recover")
            }),
            ("ASR: multiple connections, duplicate name rejection and restart restoration", {
                let f = ConfigurationFixture(); let s = f.speechConnections; var one = speechSample(.qwen).connection
                one.name = "Qwen 1"; let saved = try s.save(one, credentials: SpeechCredentials(apiKey: "one"), engine: .cloud)
                var two = SpeechConnection.preset(.qwen); two.name = "Qwen 2"
                let saved2 = try s.save(two, credentials: SpeechCredentials(apiKey: "two"), engine: .auto)
                try check(saved.credentialID != saved2.credentialID, "Keys shared")
                try check(try s.credentials(for: saved).apiKey == "one", "First key overwritten")
                two.id = UUID().uuidString
                do { _ = try s.save(two, credentials: SpeechCredentials(apiKey: "bad"), engine: .cloud); throw TestFailure(description: "Duplicate accepted") }
                catch is ConfigurationError {}
                s.reload(); try check(s.connections.count == 2 && s.active?.id == saved2.id && s.engine == .auto, "Restart lost state")
            }),
            ("ASR: key and file save failures retain selected connection and valid key", {
                let f = ConfigurationFixture(); let s = f.speechConnections; let sample = speechSample()
                let old = try s.save(sample.connection, credentials: sample.credentials, engine: .cloud)
                let initial = s.configuration; let keys = f.keys.values
                f.failingFiles.insert("speech-connections")
                var failed = false
                do { _ = try s.save(old, credentials: SpeechCredentials(apiKey: "replacement"), engine: .auto) } catch { failed = true }
                try check(failed, "Save should fail")
                try check(s.configuration == initial && f.keys.values == keys, "File failure overwrote valid settings")
                f.failingFiles.removeAll(); f.keys.failWrite = true
                do { _ = try s.save(old, credentials: SpeechCredentials(apiKey: "replacement"), engine: .auto) } catch {}
                try check(s.configuration == initial && f.keys.values == keys, "Key failure overwrote valid settings")
            }),
            ("ASR: delete selected connection returns to local without borrowing another key", {
                let f = ConfigurationFixture(); let s = f.speechConnections; let a = speechSample(), b = speechSample(.volcengine)
                let first = try s.save(a.connection, credentials: a.credentials, engine: .cloud)
                let second = try s.save(b.connection, credentials: SpeechCredentials(apiKey: "other"), engine: .cloud)
                let frozen = try s.snapshot(); try s.delete(second.id)
                try check(s.engine == .local && s.active == nil && s.connections.count == 1, "Delete silently selected a different cloud")
                try check(frozen.credentials.apiKey == "other" && (try s.credentials(for: first)).apiKey == "test-key", "Frozen or unrelated key corrupted")
            }),
            ("ASR: protocol validation rejects credential URLs and incompatible preset protocols", {
                for endpoint in ["http://example.com/audio", "wss://key:secret@example.com/ws", "wss://example.com/ws?token=secret", "wss://example.com/ws#fragment"] {
                    var c = speechSample().connection; c.endpoint = endpoint
                    do { try SpeechConnectionStore.validate(c); throw TestFailure(description: "Unsafe URL accepted") } catch is ConfigurationError {}
                }
                var c = speechSample(.volcengine).connection; c.api = .qwenRealtime
                do { try SpeechConnectionStore.validate(c); throw TestFailure(description: "Mismatched protocol") } catch is ConfigurationError {}
                var custom = speechSample(.custom).connection; custom.api = .iflytekRealtime
                custom.endpoint = SpeechAPI.iflytekRealtime.endpoint; custom.appID = "test"; custom.language = "autodialect"
                try SpeechConnectionStore.validate(custom, credentials: SpeechCredentials(apiKey: "key", apiSecret: "secret"))
            }),
            ("ASR: editor clears secrets when changing protocol and blocks busy saves", {
                let f = ConfigurationFixture(); var deps = f.speechSettings
                deps.isBusy = { true }; let editor = SpeechConnectionEditor(deps); editor.create(.custom)
                editor.credentials = SpeechCredentials(apiKey: "one", apiSecret: "secret")
                editor.changeAPI(.iflytekRealtime)
                try check(editor.credentials == SpeechCredentials() && editor.draft.credentialID == nil, "Credentials crossed protocols")
                do { try editor.save(); throw TestFailure(description: "Busy edit saved") } catch is ConfigurationError {}
                try check(f.speechConnections.connections.isEmpty, "Busy edit persisted")
            }),
            ("ASR: Qwen custom endpoint preserves path/port and replaces model exactly once", {
                var c = speechSample().connection; c.endpoint = "wss://example.test:9443/custom/realtime?model=old&region=test"; c.model = "new model"
                let url = ReliableQwenSpeechProvider.configuredURL(c)!
                let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                try check(parts.port == 9443 && parts.path == "/custom/realtime" && parts.queryItems?.filter { $0.name == "model" }.count == 1, "Endpoint rewritten")
                try check(parts.queryItems?.first { $0.name == "model" }?.value == "new model", "Wrong model")
            }),
            ("ASR: iFLYTEK signature matches independent HMAC fixture", {
                let now = ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!
                let request = try SpeechWireProtocol(speechSample(.iflytek)).request(now: now, requestID: "test-session")
                let values = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) }, uniquingKeysWith: { _, b in b })
                try check(values["signature"] == "1UJE9yLGyvPeCwAz2U9f/Lhj+3s=", "Signature mismatch")
                try check(values["utc"] == "2026-10-02T00:00:00+0000" && values["accessKeyId"] == "test-key" && values["audio_encode"] == "pcm_s16le", "Wrong auth/audio parameters")
                try check(!request.url!.absoluteString.contains("test-secret"), "Secret placed in URL")
            }),
            ("ASR: iFLYTEK corrections replace segments, stable text resists delayed partials", {
                var wire = SpeechWireProtocol(speechSample(.iflytek))
                _ = try wire.parse(iflyResult(0, text: "错字")); _ = try wire.parse(iflyResult(0, text: "正确", stable: true))
                _ = try wire.parse(iflyResult(0, text: "旧的部分"))
                let end = try wire.parse(iflyResult(1, text: "正文", stable: true, final: true))
                try check(end.text == "正确正文" && end.final, "Duplicate or stale transcript")
                let ready = try wire.parse(speechMessage(["msg_type": "action", "data": ["sessionId": "test-session"]]))
                try check(ready.ready && ready.sessionID == "test-session", "Handshake not recognized")
            }),
            ("ASR: provider error content is not surfaced as transcript or raw metadata", {
                var wire = SpeechWireProtocol(speechSample(.iflytek))
                do { _ = try wire.parse(speechMessage(["action": "error", "code": "35001", "desc": "private-secret-or-text"])); throw TestFailure(description: "Error accepted") }
                catch let error as CloudSpeechError { try check(!error.localizedDescription.contains("private-secret-or-text"), "Raw response leaked") }
            }),
            ("ASR: Doubao headers and binary frames follow chosen protocol", {
                let wire = SpeechWireProtocol(speechSample(.volcengine)); let request = try wire.request(requestID: "synthetic-request")
                try check(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key" && request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration", "Wrong credentials/resource")
                if case .data(let data) = try wire.initialFrame()! {
                    try check(Array(data.prefix(4)) == [0x11,0x10,0x10,0], "Wrong header")
                    let body = try JSONSerialization.jsonObject(with: data.dropFirst(8)) as! [String: Any]
                    try check((body["audio"] as? [String: Any])?["rate"] as? Int == 16000, "Wrong rate")
                } else { throw TestFailure(description: "Missing binary initial frame") }
                if case .data(let end) = try wire.endFrame(sessionID: "") { try check(Array(end) == [0x11,0x22,0,0,0,0,0,0], "Wrong end marker") }
            }),
            ("ASR: Doubao full hypotheses replace and malformed frames fail", {
                var wire = SpeechWireProtocol(speechSample(.volcengine))
                _ = try wire.parse(volcResult("部分"))
                let final = try wire.parse(volcResult("完整正文", final: true)); try check(final.text == "完整正文" && final.final, "Not full hypothesis")
                for malformed in [Data(), Data([0x11,0x90,0x10,0,0,0,0,9]), Data([0x11,0x90,0x11,0,0,0,0,0])] {
                    do { _ = try wire.parse(.data(malformed)); throw TestFailure(description: "Malformed accepted") } catch is CloudSpeechError {}
                }
            }),
            ("ASR: streaming buffers before handshake, paces frames and sends end last", {
                let socket = FakeSpeechSocket(); let provider = StreamingSpeechProvider(snapshot: speechSample(.iflytek), makeSocket: { socket })
                var partial = "", result: String?, errors = 0
                provider.connect(apiKey: nil, model: "", onPartial: { partial = $0 }, onFinal: { _ in }, onError: { _ in errors += 1 })
                provider.sendAudio(Data(repeating: 0, count: 2560))
                spin(0.08); try check(socket.messages.isEmpty, "Audio sent before service handshake")
                socket.onSend = { message in if case .string = message { socket.emit(try! iflyResult(0, text: "合成识别", stable: true, final: true)) } }
                socket.emit(try speechMessage(["msg_type": "action", "data": ["sessionId": "sid"]]))
                spin(0.2, until: { provider.isReady })
                provider.finish { result = $0 }
                spin(1, until: { result != nil })
                try check(result == "合成识别" && partial == "合成识别" && errors == 0, "Final callback failed")
                let messages = socket.messages; try check(messages.count == 3, "Wrong audio/end frame count")
                if case .string(let end) = messages.last! { try check(end.contains("sid") && end.contains("end"), "Missing session end") } else { throw TestFailure(description: "End frame missing") }
                provider.disconnect()
            }),
            ("ASR: Doubao drains PCM frames before final marker and delivers one final", {
                let socket = FakeSpeechSocket(), sample = speechSample(.volcengine)
                let provider = StreamingSpeechProvider(snapshot: sample, makeSocket: { socket })
                var result: String?, errors = 0, finals = 0
                socket.onSend = { message in
                    if case .data(let data) = message, data.count >= 8, data[1] == 0x22 {
                        socket.emit(try! volcResult("完整合成识别", final: true))
                    }
                }
                provider.connect(apiKey: nil, model: "", onPartial: { _ in }, onFinal: { _ in finals += 1 }, onError: { _ in errors += 1 })
                provider.sendAudio(Data(repeating: 7, count: 12800)); provider.finish { result = $0 }
                spin(1.5, until: { result != nil || errors > 0 })
                let frames = socket.messages.compactMap { message -> Data? in if case .data(let data) = message { return data }; return nil }
                try check(frames.count == 4 && frames.first?[1] == 0x10 && frames.last?[1] == 0x22, "Initial/audio/end order wrong")
                try check(frames.dropFirst().dropLast().reduce(0) { $0 + $1.count - 8 } == 12800, "PCM was dropped")
                try check(result == "完整合成识别" && errors == 0 && finals == 1 && !provider.isReady, "Final or closed state wrong")
                provider.disconnect()
            }),
            ("ASR: early final while stopping cannot silently discard buffered audio", {
                let socket = FakeSpeechSocket(), sample = speechSample(.iflytek)
                let provider = StreamingSpeechProvider(snapshot: sample, makeSocket: { socket })
                var failures = 0, finals = 0, completions = 0
                provider.connect(apiKey: nil, model: "", onPartial: { _ in }, onFinal: { _ in finals += 1 }, onError: { _ in failures += 1 })
                provider.sendAudio(Data(repeating: 0, count: 32000))
                provider.finish { if $0 == nil { completions += 1 } }
                socket.emit(try speechMessage(["msg_type": "action", "data": ["sessionId": "test"]]))
                socket.emit(try iflyResult(0, text: "提前结束", final: true))
                spin(0.5, until: { completions > 0 })
                try check(failures == 1 && finals == 0 && completions == 1, "Early termination claimed success")
                provider.disconnect()
            }),
            ("ASR: HTTP empty capture finishes disconnected without upload", {
                MockProtocol.reset([])
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
                let provider = HTTPTranscriptionProvider(snapshot: speechSample(.custom), configuration: config)
                var result: String?, errors = 0
                provider.connect(apiKey: nil, model: "", onPartial: { _ in }, onFinal: { _ in }, onError: { _ in errors += 1 })
                provider.finish { result = $0 }; spin(0.2, until: { result != nil })
                try check(result == "" && errors == 0 && !provider.isReady && MockProtocol.requests.isEmpty, "Empty capture uploaded or stayed connected")
                provider.disconnect()
            }),
            ("ASR: cancel suppresses late socket results and setup timeout completes once", {
                let socket = FakeSpeechSocket(); let provider = StreamingSpeechProvider(snapshot: speechSample(.iflytek), makeSocket: { socket }, setupTimeout: 0.08, finalTimeout: 0.08)
                var output = 0, errors = 0
                provider.connect(apiKey: nil, model: "", onPartial: { _ in output += 1 }, onFinal: { _ in output += 1 }, onError: { _ in errors += 1 })
                spin(0.25, until: { errors > 0 }); try check(errors == 1, "Setup did not time out")
                provider.disconnect(); spin(0.03)
                socket.emit(try iflyResult(0, text: "late", final: true)); spin(0.06)
                try check(output == 0 && errors == 1 && socket.closed, "Cancelled callback escaped")
            }),
            ("ASR: stream send failure and buffer limit report errors instead of dropping audio", {
                for oversized in [false, true] {
                    let socket = FakeSpeechSocket(); socket.sendFailure = !oversized
                    let provider = StreamingSpeechProvider(snapshot: speechSample(.volcengine), makeSocket: { socket })
                    var errors = 0
                    provider.connect(apiKey: nil, model: "", onPartial: { _ in }, onFinal: { _ in }, onError: { _ in errors += 1 })
                    if oversized { provider.sendAudio(Data(repeating: 0, count: 960002)) }
                    spin(0.5, until: { errors > 0 }); try check(errors == 1, "Audio loss was silent")
                    provider.disconnect()
                }
            }),
            ("ASR: recording snapshot survives selection changes and cancelled callbacks", {
                var sample = speechSample(.qwen); var made: [FakeCloudSpeechProvider] = []
                let service = CloudSpeechService(snapshotProvider: { sample }, factory: { snapshot in let p = FakeCloudSpeechProvider(snapshot.connection.id); made.append(p); return p })
                var texts: [String] = []
                service.connect(onPartial: { texts.append($0) }, onFinal: { texts.append($0) }, onError: { _ in })
                let original = made[0]; sample = speechSample(.volcengine)
                service.preconnect(); try check(made.count == 1, "Preconnect replaced active recording")
                service.disconnect(); original.partial?("stale")
                service.connect(onPartial: { texts.append($0) }, onFinal: { texts.append($0) }, onError: { _ in })
                made.last?.partial?("current"); spin(0.02)
                try check(texts == ["current"] && made.count == 2 && original.disconnected, "Session leaked across connections")
                service.disconnect()
            }),
            ("ASR: Qwen-only preconnection never starts idle sessions on new vendors", {
                for vendor in [SpeechVendor.iflytek, .volcengine, .custom, .qwen] {
                    let sample = speechSample(vendor); let provider = FakeCloudSpeechProvider(sample.connection.id)
                    let service = CloudSpeechService(snapshotProvider: { sample }, factory: { _ in provider })
                    service.preconnect(); try check(provider.preconnectCount == (vendor == .qwen ? 1 : 0), "Idle billable session created")
                    service.disconnect()
                }
            }),
            ("ASR: custom HTTP WAV and multipart body use audio endpoint and no AI context", {
                let sample = speechSample(.custom), pcm = Data([1,0,2,0])
                let request = try HTTPTranscriptionProvider.request(snapshot: sample, pcm: pcm, boundary: "test-boundary")
                let body = String(decoding: request.httpBody!, as: UTF8.self)
                try check(request.url!.path == "/audio/transcriptions" && request.httpMethod == "POST", "Wrong endpoint")
                try check(body.contains("whisper-compatible") && body.contains("speech.wav") && !body.contains("prompt") && !body.contains("test-key"), "Wrong body")
                let wav = HTTPTranscriptionProvider.wav(pcm)
                try check(wav.count == 48 && wav.suffix(4) == pcm && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF", "Invalid WAV")
            }),
            ("ASR: HTTP uploads only after stop and returns final", {
                MockProtocol.reset([.init(json: ["text": "合成转录"])])
                let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockProtocol.self]
                let provider = HTTPTranscriptionProvider(snapshot: speechSample(.custom), configuration: configuration)
                var output: String?, errors = 0
                provider.connect(apiKey: nil, model: "", onPartial: { _ in throwaway() }, onFinal: { _ in }, onError: { _ in errors += 1 })
                provider.sendAudio(Data(repeating: 0, count: 3200)); spin(0.02)
                try check(MockProtocol.requests.isEmpty, "Uploaded during recording")
                provider.finish { output = $0 }; spin(1, until: { output != nil || errors > 0 })
                try check(output == "合成转录" && errors == 0 && MockProtocol.requests.count == 1, "HTTP final failed")
                provider.disconnect()
            }),
            ("ASR: credential retry preserves unsaved connection fields", {
                let f = ConfigurationFixture(), sample = speechSample()
                let c = try f.speechConnections.save(sample.connection, credentials: sample.credentials, engine: .cloud)
                f.keys.failRead = true
                let editor = SpeechConnectionEditor(f.speechSettings); editor.load(c)
                try check(editor.keyLoadFailed, "Locked credential not reported")
                editor.draft.model = "unsaved-model"
                do { try editor.save(); throw TestFailure(description: "Unread key saved") } catch is ConfigurationError {}
                f.keys.failRead = false; editor.retryCredentialRead()
                try check(editor.draft.model == "unsaved-model" && editor.credentials == sample.credentials && editor.isDirty, "Retry lost draft")
                editor.discard(); try check(!editor.isDirty && editor.draft.model == c.model, "Discard did not restore saved value")
            }),
            ("ASR: corrupt storage is retained and blocks partial overwrite", {
                let f = ConfigurationFixture(), sample = speechSample()
                let s = f.speechConnections
                try s.save(sample.connection, credentials: sample.credentials, engine: .cloud)
                let before = s.configuration, keys = f.keys.values
                let corrupt = Data("{broken".utf8); try corrupt.write(to: f.file("speech-connections").url)
                s.reload()
                try check(s.loadError != nil && s.configuration == before, "Corruption erased loaded state")
                do { try s.select(nil, engine: .local); throw TestFailure(description: "Overwrote corrupt file") } catch is ConfigurationError {}
                try check(try Data(contentsOf: f.file("speech-connections").url) == corrupt && f.keys.values == keys, "Corrupt source or keys changed")
            }),
            ("ASR: selecting another saved connection preserves automatic local fallback", {
                let f = ConfigurationFixture(), first = speechSample(), second = speechSample(.volcengine)
                let a = try f.speechConnections.save(first.connection, credentials: first.credentials, engine: .cloud)
                try f.speechConnections.save(second.connection, credentials: second.credentials, engine: .auto)
                let editor = SpeechConnectionEditor(f.speechSettings)
                try editor.select(a)
                try check(f.speechConnections.active?.id == a.id && f.speechConnections.engine == .auto, "Switch discarded fallback preference")
            }),
            ("ASR: saved engine repairs stale legacy preference on restart", {
                let f = ConfigurationFixture(), sample = speechSample()
                try f.speechConnections.save(sample.connection, credentials: sample.credentials, engine: .cloud)
                f.defaults.set(SpeechRecognitionProvider.local.rawValue, forKey: "speechRecognitionProvider")
                f.speechConnections.reload()
                try check(f.defaults.string(forKey: "speechRecognitionProvider") == SpeechRecognitionProvider.cloud.rawValue, "Recording would use stale engine")
            }),
            ("ASR: streaming stop timeout completes once even when error handler disconnects", {
                let sample = speechSample(.iflytek), socket = FakeSpeechSocket()
                let provider = StreamingSpeechProvider(snapshot: sample, makeSocket: { socket }, finalTimeout: 0.1)
                let service = CloudSpeechService(snapshotProvider: { sample }, factory: { _ in provider })
                var errors = 0, completions = 0
                service.connect(onPartial: { _ in }, onFinal: { _ in }, onError: { _ in errors += 1; service.disconnect() })
                socket.emit(try speechMessage(["msg_type": "action", "data": ["sessionId": "test"]]))
                spin(0.3, until: { service.isReady })
                service.sendAudio(Data(repeating: 0, count: 1280))
                service.finish { value in if value == nil { completions += 1 } }
                spin(0.7, until: { completions > 0 }); spin(0.1)
                try check(errors == 1 && completions == 1, "Failed stop hung or completed twice")
            }),
            ("ASR: HTTP empty, API error and timeout finish without leaking response content", {
                let plans: [MockProtocol.Reply] = [.init(json: ["text": " "]), .init(json: ["error": "private response"], status: 401), .init(json: [:], error: URLError(.timedOut))]
                for plan in plans {
                    MockProtocol.reset([plan])
                    let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockProtocol.self]
                    let sample = speechSample(.custom), provider = HTTPTranscriptionProvider(snapshot: speechSample(.custom), configuration: c)
                    let service = CloudSpeechService(snapshotProvider: { sample }, factory: { _ in provider })
                    var failures: [String] = [], completions = 0, finals = 0
                    service.connect(onPartial: { _ in }, onFinal: { _ in finals += 1 }, onError: { failures.append($0.localizedDescription); service.disconnect() })
                    service.sendAudio(Data(repeating: 0, count: 3200)); service.finish { if $0 == nil { completions += 1 } }
                    spin(1, until: { completions > 0 })
                    try check(completions == 1 && failures.count == 1 && finals == 0 && !failures[0].contains("private response"), "Failure leaked or hung")
                }
            }),
            ("ASR: cancelling an in-flight HTTP upload suppresses all late callbacks", {
                MockProtocol.reset([.init(json: ["text": "late result"], delay: 0.15)])
                let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockProtocol.self]
                let provider = HTTPTranscriptionProvider(snapshot: speechSample(.custom), configuration: c)
                var callbacks = 0
                provider.connect(apiKey: nil, model: "", onPartial: { _ in callbacks += 1 }, onFinal: { _ in callbacks += 1 }, onError: { _ in callbacks += 1 })
                provider.sendAudio(Data(repeating: 0, count: 3200)); provider.finish { _ in callbacks += 1 }
                spin(0.1, until: { !MockProtocol.requests.isEmpty }); provider.disconnect(); spin(0.3)
                try check(callbacks == 0 && provider.connectionState == .idle, "Cancelled request delivered text")
            }),
            ("ASR: failed finalization preserves partial text with a separate notice and no AI call", {
                MockProtocol.reset([])
                let f = ConfigurationFixture(), network = Fixture()
                let vm = RecordingViewModel(snapshotProvider: { try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults) },
                    modeNameProvider: { "测试" }, processor: network.service(), stopCapture: {}, cancelCapture: {})
                var output: String?
                vm.onComplete = { text, _ in output = text }
                vm.captureStopped(); vm.handleCloudRecognitionFailure("合成网络错误")
                vm.processAndInput("已识别的部分")
                try check(output == "已识别的部分" && vm.fallbackNotice?.contains("遗漏") == true && MockProtocol.requests.isEmpty, "Incomplete recognition treated as complete")
            }),
            ("ASR: finalization failure without text is visible and cannot submit an empty result", {
                let vm = RecordingViewModel(snapshotProvider: { throw TestFailure(description: "Unused AI") }, modeNameProvider: { "测试" }, stopCapture: {}, cancelCapture: {})
                var notices: [String] = [], delivered = false, cancelled = false
                vm.onRecognitionFailure = { notices.append($0) }; vm.onComplete = { _, _ in delivered = true }; vm.onCancel = { cancelled = true }
                vm.captureStopped(); vm.handleCloudRecognitionFailure("合成接口错误"); vm.processAndInput("")
                try check(notices.count == 1 && notices[0].contains("合成接口错误") && cancelled && !delivered && !vm.isProcessing, "Empty failure hidden or processing stuck")
            })
        ]
    }
    static func throwaway() {}
}

private final class RecoveryProcessorStub: RecoveryTextProcessing {
    struct Request {
        let text: String
        let snapshot: AIProcessingSnapshot
        let finish: (Result<String, Error>) -> Void
    }
    var requests: [Request] = []
    var cancellations = 0
    func process(text: String, snapshot: AIProcessingSnapshot, completion: @escaping (Result<String, Error>) -> Void) {
        requests.append(Request(text: text, snapshot: snapshot, finish: completion))
    }
    func cancelCurrentTask() { cancellations += 1 }
}

@MainActor
private final class RecoveryFixture {
    let config = ConfigurationFixture()
    let processor = RecoveryProcessorStub()
    var copied: [String] = []
    var delivered: [String] = []
    var copySucceeds = true
    var allowsStart = true
    var recovery: InputRecoveryStore!

    init(activity: StateManager? = nil) throws {
        _ = try config.connections.save(.preset(.qwen), key: "synthetic-recovery-key")
        recovery = InputRecoveryStore(modes: config.modes, processor: processor, activity: activity,
            snapshotProvider: { [config] id in
                try AIProcessingSnapshot.capture(modes: config.modes, connections: config.connections, defaults: config.defaults, modeID: id)
            }, canStart: { [weak self] in self?.allowsStart == true }, copyText: { [weak self] text in
                self?.copied.append(text)
                return self?.copySucceeds == true
            })
        recovery.onProcessed = { [weak self] in self?.delivered.append($0) }
    }
}

private extension AIProcessingRegression {
    @MainActor
    static func recoveryTests() -> [(String, () throws -> Void)] {
        [
            ("Recovery: retains exact ASR original and ignores empty captures", {
                let f = try RecoveryFixture(), store = f.recovery!
                let original = "  八哥与 A P I\n未整理的原文  "
                store.capture(original, mayBeIncomplete: true)
                let id = store.entry?.id
                store.capture(" \n\t")
                store.copyDisplayedText()
                try check(store.entry?.id == id && store.entry?.original == original && f.copied == [original], "Original altered or replaced by empty input")
                try check(f.delivered.isEmpty && f.processor.requests.isEmpty, "Copy unexpectedly processed or injected original")
                try check(store.entry?.mayBeIncomplete == true, "Partial recognition lost its warning")
                store.capture("下一次原文")
                try check(store.entry?.id != id && store.selectedModeID == nil && store.result == nil && store.entry?.mayBeIncomplete == false, "New transcript did not reset recovery")
                let fresh = try RecoveryFixture()
                try check(fresh.recovery.entry == nil && !fresh.recovery.canReprocess, "Recovery persisted across instances")
            }),
            ("Recovery: scene selection is local, preserves results and snapshots current settings", {
                let f = try RecoveryFixture(), store = f.recovery!
                try f.config.modes.select(WritingScene.workMessage.storageID)
                store.capture("原文 A P I"); store.prepareForPresentation()
                try check(store.selectedModeID == WritingScene.workMessage.storageID, "Initial scene not inherited")
                store.selectMode(WritingScene.meetingNotes.storageID)
                store.prepareForPresentation()
                try check(f.processor.requests.isEmpty && f.config.modes.selected.builtin == .workMessage && store.selectedModeID == WritingScene.meetingNotes.storageID, "Selection submitted, reset or changed global mode")
                f.config.defaults.set(TranslateLanguage.english.rawValue, forKey: "translateLang")
                store.reprocess()
                store.selectMode(WritingScene.formalDocument.storageID)
                let request = f.processor.requests[0]
                try check(request.snapshot.mode.builtin == .meetingNotes && request.snapshot.language == .english && request.text == "原文 API", "Wrong scene, language or source")
                try check(store.selectedModeID == WritingScene.meetingNotes.storageID, "Changed locked scene")
                request.finish(.success("第一轮结果")); spin(0.1, until: { !store.isProcessing })
                store.selectMode(WritingScene.aiInstruction.storageID)
                try check(store.result == "第一轮结果" && store.resultMode?.builtin == .meetingNotes && f.processor.requests.count == 1, "Selection destroyed or relabeled old result")
                f.config.defaults.set(TranslateLanguage.japanese.rawValue, forKey: "translateLang")
                store.reprocess()
                try check(store.result == nil && store.display == .original && f.processor.requests[1].text == "原文 API", "Rerun used previous result")
                try check(f.processor.requests[1].snapshot.mode.builtin == .aiInstruction && f.processor.requests[1].snapshot.language == .japanese, "Rerun did not refresh settings")
                store.cancelProcessing()
            }),
            ("Recovery: canceled and replaced requests cannot deliver stale results", {
                let f = try RecoveryFixture(), store = f.recovery!
                store.capture("旧原文"); store.reprocess(); store.cancelProcessing()
                f.processor.requests[0].finish(.success("迟到结果")); spin(0.1)
                try check(store.result == nil && store.notice?.contains("取消") == true && f.delivered.isEmpty, "Canceled request completed or injected")
                store.reprocess(); store.capture("新原文"); store.reprocess()
                f.processor.requests[1].finish(.success("过期旧结果")); spin(0.1)
                try check(store.isProcessing && store.result == nil && store.entry?.original == "新原文", "Replaced request overwrote new entry")
                f.processor.requests[2].finish(.success("新结果")); spin(0.1, until: { !store.isProcessing })
                try check(store.result == "新结果" && f.processor.cancellations == 2 && f.delivered == ["新结果"], "Current request failed or stale request injected")
            }),
            ("Recovery: explicit processing delivers validated output once to its captured destination", {
                let f = try RecoveryFixture(), store = f.recovery!
                var first: [String] = [], second: [String] = []
                store.onProcessed = { first.append($0) }
                store.capture("保留的原文"); store.reprocess()
                store.onProcessed = { second.append($0) }
                let request = f.processor.requests[0]
                request.finish(.success("整理后的结果")); spin(0.1, until: { !store.isProcessing })
                request.finish(.success("重复回调")); spin(0.1)
                try check(first == ["整理后的结果"] && second.isEmpty, "Delivery duplicated or destination changed in flight")
                store.prepareForPresentation(); store.display = .original; store.copyDisplayedText()
                store.selectMode(WritingScene.meetingNotes.storageID)
                try check(first.count == 1 && second.isEmpty && f.copied.last == "保留的原文" && store.result == "整理后的结果",
                          "Reopen, copy or scene selection injected again or lost retained content")
            }),
            ("Recovery: delivery keeps activity busy through the handoff to injection", {
                let activity = StateManager.shared
                activity.transition(to: .idle); defer { activity.transition(to: .idle) }
                let f = try RecoveryFixture(activity: activity), store = f.recovery!
                var installed = false, deliveredWhileRecovering = false
                let updates = AppUpdateService(isBusy: { activity.isBusy() })
                store.onProcessed = { _ in
                    deliveredWhileRecovering = activity.currentState == .recovering
                    store.cancelProcessing(); store.onProcessed = nil
                    activity.transition(to: .injecting)
                }
                store.capture("原文"); store.reprocess()
                try check(updates.postponeInstallationIfBusy { installed = true }, "Update did not wait for recovery")
                f.processor.requests[0].finish(.success("可输入的结果")); spin(0.1, until: { !store.isProcessing })
                updates.activityDidChange()
                try check(deliveredWhileRecovering && activity.currentState == .injecting && !installed,
                          "Recovery released activity during delivery or overwrote injection state")
                activity.transition(to: .idle); updates.activityDidChange()
                try check(installed, "Completed injection did not release installation")
            }),
            ("Recovery: failures and unsafe output retain copyable original", {
                let f = try RecoveryFixture(), store = f.recovery!
                store.capture("可找回的原文")
                for outcome: Result<String, Error> in [.failure(MiniMaxError.timeout), .success("   "), .success("<think>unfinished")] {
                    store.reprocess(); f.processor.requests.last!.finish(outcome)
                    spin(0.1, until: { !store.isProcessing })
                    store.copyDisplayedText()
                    try check(store.result == nil && store.notice != nil && f.copied.last == "可找回的原文" && f.delivered.isEmpty, "Failure changed raw, injected or exposed unsafe output")
                }
                store.reprocess(); f.processor.requests.last!.finish(.success("可复制的结果"))
                spin(0.1, until: { !store.isProcessing }); store.copyDisplayedText()
                store.display = .original; store.copyDisplayedText()
                try check(Array(f.copied.suffix(2)) == ["可复制的结果", "可找回的原文"], "Copy ignored selected tab")
                f.copySucceeds = false; store.copyDisplayedText()
                try check(store.copyNotice?.contains("失败") == true, "Clipboard failure hidden")
            }),
            ("Recovery: deleted custom scene fails without modifying global selection or prior result", {
                let f = try RecoveryFixture(), store = f.recovery!
                var custom = f.config.modes.draft(); custom.name = "合成自定义"
                try f.config.modes.save(custom, baseRules: f.config.modes.configuration.baseRules)
                store.capture("合成原文"); store.selectMode(custom.id); store.reprocess()
                try check(f.processor.requests[0].snapshot.mode.isCustom, "Custom scene missing")
                f.processor.requests[0].finish(.success("已完成结果")); spin(0.1, until: { !store.isProcessing })
                try f.config.modes.delete(custom.id)
                store.reprocess()
                try check(f.processor.requests.count == 1 && store.result == "已完成结果" && store.notice?.contains("删除") == true, "Deleted scene silently changed or erased result")
                try check(f.config.modes.selected.builtin == .rawTranscript, "Local scene leaked to global defaults")
            }),
            ("Recovery: new recording synchronously cancels rerun without erasing incoming state", {
                let activity = StateManager.shared
                activity.transition(to: .idle)
                defer { activity.transition(to: .idle) }
                let f = try RecoveryFixture(activity: activity), store = f.recovery!
                store.capture("测试原文"); store.reprocess()
                try check(activity.currentState == .recovering && store.isProcessing && !store.inputIsBusy, "Recovery canceled its own request")
                var installed = false
                let updates = AppUpdateService(isBusy: { activity.isBusy() })
                try check(updates.postponeInstallationIfBusy { installed = true }, "Update interrupted recovery")
                activity.transition(to: .recording)
                try check(activity.currentState == .recording && !store.isProcessing && store.inputIsBusy && !store.canReprocess, "Recovery clobbered normal recording state")
                updates.activityDidChange()
                try check(!installed, "Update installed during new recording")
                f.processor.requests[0].finish(.success("迟到结果")); spin(0.1)
                try check(store.result == nil && f.delivered.isEmpty, "Normal recording accepted or injected late recovery result")
                activity.transition(to: .idle); updates.activityDidChange()
                try check(installed && store.canReprocess, "Completion did not release activity lock")
                f.allowsStart = false; store.reprocess()
                try check(f.processor.requests.count == 1, "Recovery started during installation")
            }),
            ("Recovery: original capture survives AI cancellation, rejects canceled ASR and preserves incomplete flags", {
                let f = try RecoveryFixture(), store = f.recovery!
                store.capture("更早原文")
                let vm = RecordingViewModel(snapshotProvider: { throw MiniMaxError.missingAPIKey }, modeNameProvider: { "测试" },
                    stopCapture: {}, cancelCapture: {}, retainOriginal: { store.capture($0, mayBeIncomplete: $1) })
                vm.retainRecognizedOriginal("最终原文 A P I", mayBeIncomplete: false)
                vm.cancel(); vm.retainRecognizedOriginal("迟到识别", mayBeIncomplete: false)
                try check(store.entry?.original == "最终原文 A P I", "AI cancel lost original or canceled ASR replaced it")
                let earlyCancel = RecordingViewModel(stopCapture: {}, cancelCapture: {}, retainOriginal: { store.capture($0, mayBeIncomplete: $1) })
                earlyCancel.cancel(); earlyCancel.retainRecognizedOriginal("不应保留", mayBeIncomplete: false)
                try check(store.entry?.original == "最终原文 A P I", "Pre-final cancellation overwrote original")
                let incomplete = RecordingViewModel(snapshotProvider: { throw MiniMaxError.missingAPIKey }, modeNameProvider: { "测试" },
                    stopCapture: {}, cancelCapture: {}, retainOriginal: { store.capture($0, mayBeIncomplete: $1) })
                incomplete.captureStopped(); incomplete.handleCloudRecognitionFailure("合成失败")
                incomplete.retainRecognizedOriginal("部分文字", mayBeIncomplete: false)
                try check(store.entry?.mayBeIncomplete == true && store.entry?.original == "部分文字", "Recognition failure flag lost")
                StateManager.shared.transition(to: .idle)
            }),
            ("Recovery: floating entry stays available after audio and partial recognition", {
                let vm = RecordingViewModel(stopCapture: {}, cancelCapture: {})
                vm.isRecording = true
                try check(!vm.canRecoverInput, "Empty history enabled")
                vm.hasRecoverableInput = true
                try check(vm.canRecoverInput && vm.panelHeight == 224, "Ready entry disabled or height changed")
                vm.hasDetectedSpeech = true
                try check(vm.canRecoverInput, "Audio or noise disabled recovery before transcript")
                vm.hasDetectedSpeech = false; vm.partialText = "非空口述"
                try check(vm.canRecoverInput, "Partial recognition disabled recovery")
                vm.hasDetectedSpeech = true
                try check(vm.canRecoverInput, "Combined speech and transcript disabled recovery")
                vm.isCaptureReady = false; vm.isAudioBuffered = true
                try check(vm.canRecoverInput, "Buffered recording disabled recovery")
                vm.partialText = ""; vm.isRecording = false; vm.isProcessing = true
                try check(!vm.canRecoverInput && vm.panelHeight == 224, "Processing enabled recovery or changed height")
                vm.isRecording = true; vm.isProcessing = false; vm.isCancelled = true
                try check(!vm.canRecoverInput, "Canceled session enabled recovery")
            }),
            ("Recovery: choosing last input after misrecognition cancels without retaining or injecting this recording", {
                let f = try RecoveryFixture(), store = f.recovery!, transport = Fixture()
                store.capture("需要找回的上一次原文")
                let previousID = store.entry?.id
                let reference = WeakRecordingModel()
                var canceled = 0, stopped = 0, injected: [String] = []
                let vm = RecordingViewModel(snapshotProvider: { throw TestFailure(description: "Canceled recording must not process") },
                    modeNameProvider: { "测试" }, processor: transport.service(), stopCapture: { stopped += 1 },
                    cancelCapture: {
                        canceled += 1
                        reference.value?.retainRecognizedOriginal("取消时到达的误识别", mayBeIncomplete: false)
                        reference.value?.processAndInput("取消时到达的误识别")
                    }, retainOriginal: { store.capture($0, mayBeIncomplete: $1) })
                reference.value = vm
                vm.isRecording = true; vm.isCaptureReady = true; vm.hasRecoverableInput = true
                vm.hasDetectedSpeech = true; vm.partialText = "环境声触发的临时识别"
                vm.onComplete = { text, _ in injected.append(text) }
                vm.onRecover = { reference.value?.cancel(); store.prepareForPresentation() }
                try check(vm.canRecoverInput, "Misrecognition prevented opening recovery")
                vm.onRecover?()
                vm.retainRecognizedOriginal("取消后迟到的原文", mayBeIncomplete: false)
                vm.processAndInput("取消后迟到的识别结果")
                vm.finishAIProcessing(.success("取消后迟到的整理结果"), originalText: "误识别")
                try check(canceled == 1 && stopped == 0 && vm.isCancelled && !vm.isRecording,
                          "Recovery finalized the discarded recording instead of canceling it")
                store.copyDisplayedText()
                try check(store.entry?.id == previousID && f.copied == ["需要找回的上一次原文"] && injected.isEmpty,
                          "Discarded speech overwrote history or entered the target input")
            }),
            ("Recovery: speech activity handles silent, interleaved and native float audio", {
                for interleaved in [false, true] {
                    for format in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
                        let audioFormat = AVAudioFormat(commonFormat: format, sampleRate: 48000, channels: 2, interleaved: interleaved)!
                        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 200)!
                        buffer.frameLength = 200
                        for ch in 0..<(interleaved ? 1 : 2) {
                            let length = interleaved ? 400 : 200
                            if let data = buffer.int16ChannelData { data[ch].initialize(repeating: 0, count: length) }
                            if let data = buffer.floatChannelData { data[ch].initialize(repeating: 0, count: length) }
                        }
                        try check(!PCMVoiceActivityDetector.containsMeaningfulSpeech(buffer), "Silence detected as speech")
                        for index in 0..<10 {
                            let ch = interleaved ? 0 : 1, offset = interleaved ? index * 2 + 1 : index
                            buffer.int16ChannelData?[ch][offset] = 1000
                            buffer.floatChannelData?[ch][offset] = 0.1
                        }
                        try check(PCMVoiceActivityDetector.containsMeaningfulSpeech(buffer), "Speech on second channel not detected")
                    }
                }
            }),
            ("Recovery: constructing views never reads keys or submits requests", {
                let f = try RecoveryFixture(), store = f.recovery!
                let reads = f.config.keys.reads
                store.capture("原文"); store.prepareForPresentation()
                _ = InputRecoveryView(recovery: store, onClose: {}).body
                store.selectMode(WritingScene.aiInstruction.storageID)
                try check(f.config.keys.reads == reads && f.processor.requests.isEmpty, "UI or scene selection read credentials or submitted")
            })
        ]
    }
}
