import Foundation
import SwiftUI
import AVFoundation

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
    lazy var modes = ModeStore(defaults: defaults, file: file("modes"), backupFile: file("backup"))
    lazy var connections = ModelConnectionStore(defaults: defaults, file: file("connections"), keys: keys)
    init(_ values: [String: Any] = [:]) { defaults = MemoryDefaults(values) }
    var speechSettings: SpeechSettingsDependencies {
        SpeechSettingsDependencies(defaults: defaults, readKey: { "synthetic-speech-key" }, saveKey: { _ in true },
            refreshConnection: { _ in }, providers: { [("qwen-realtime", "千问实时识别"), ("dashscope", "阿里云 FunASR")] },
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
            ("Raw transcription does not request AI or Keychain", {
                MockProtocol.reset([])
                let f = Fixture()
                let service = MiniMaxService(defaults: f.defaults, session: f.session, apiKeyProvider: { fatalError("Raw mode accessed Keychain") })
                try check(try process(service, mode: .rawTranscript).get() == input, "Raw text changed")
                try check(MockProtocol.requests.isEmpty, "Raw mode requested AI")
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
        ] + configurationTests() + reviewTests() + outputGuardTests()
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
            ("Built-in scene rules preserve tasks while the common base allows generation", {
                for scene in WritingScene.allCases where scene != .rawTranscript {
                    let rules = PromptComposer.defaultSceneRules(for: scene)
                    try check(!rules.contains("{text}"), "Placeholder leaked into new scene")
                    try check(!rules.contains(AIProcessingService.sceneSafetyRules), "Legacy base duplicated")
                    try check(rules.contains("只整理原话"), "Built-in became an answering mode")
                }
                try check(PromptComposer.defaultSceneRules(for: .aiInstruction).contains("只整理指令"), "AI instruction task changed")
                let mode = ModeDefinition(id: UUID().uuidString, name: "问答", sceneRules: "直接回答问题")
                let result = PromptComposer.systemPrompt(mode: mode, baseRules: "共同规则", language: .japanese, personalContext: "称呼：不该注入的名字\n领域：测试")
                try check(result.contains("共同规则") && result.contains("直接回答问题") && result.contains("日文"), "Composition lost a section")
                try check(!result.contains("不该注入的名字") && result.contains("领域：测试"), "Personal context filtering regressed")
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
                try check(!messages[0]["content"]!.contains(input) && messages[0]["content"]!.contains("共同规则"), "System prompt incorrect")
                try check(sent["max_tokens"] as? Int == 8192 && sent["temperature"] == nil, "Custom generation uses short-input budget or invalid Kimi temperature")
            }),
            ("Raw snapshot bypasses prompt and key reads; translation still requests AI", {
                let f = ConfigurationFixture()
                f.keys.failRead = true
                let raw = try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults)
                try check(!raw.requiresAI && raw.apiKey.isEmpty && f.keys.reads == 0, "Raw snapshot touched keys")
                f.keys.failRead = false
                _ = try f.connections.save(.preset(.qwen), key: "test")
                f.defaults.set(TranslateLanguage.english.rawValue, forKey: "translateLang")
                let translated = try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults)
                try check(translated.requiresAI && translated.systemPrompt.contains("英文") && translated.systemPrompt.contains("仅在指定输出语言"), "Raw translation path lost")
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
                try check(prompt.contains("OLD-BASE") && prompt.contains("OLD-CONTEXT") && !prompt.contains("NEW-CONTEXT") && !prompt.contains("最终输出语言必须是日文"), "Snapshot reread rules/context/language")
                try check(MockProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer old-key" }, "Snapshot reread key")
            }),
            ("Automatic finalization freezes once and ignores duplicate or cancelled results", {
                let mode = ModeDefinition.preset(.rawTranscript)
                let snapshot = AIProcessingSnapshot(mode: mode, language: .original, systemPrompt: "", connection: nil, apiKey: "")
                var captures = 0; var outputs = 0
                let vm = RecordingViewModel(snapshotProvider: { captures += 1; return snapshot }, modeNameProvider: { "raw" }, stopCapture: {}, cancelCapture: {})
                vm.onComplete = { _, _ in outputs += 1 }
                vm.processAndInput(input); vm.processAndInput(input)
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
        MockProtocol.reset(Array(repeating: .init(json: answer("OK · 本地模拟结果"), delay: 0.3), count: 100))
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
                let menu = ContentView(onOpenSettings: { _ in }, modes: f.modes, connections: f.connections, defaults: f.defaults)
                let settings = SettingsView(modes: f.modes, connections: f.connections, defaults: f.defaults,
                    speechDependencies: f.speechSettings, connectionTestService: service)
                let vm = RecordingViewModel(snapshotProvider: { try AIProcessingSnapshot.capture(modes: f.modes, connections: f.connections, defaults: f.defaults) },
                    modeNameProvider: { f.modes.selected.name }, processor: service, stopCapture: {}, cancelCapture: {})
                let panel = RecordingPanelView(viewModel: vm, modes: f.modes)
                _ = menu.body; _ = settings.body; _ = panel.body
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
                try check(result == input && captures == 1 && vm.displayStatus == "原样转写", "Delayed ASR captured later settings")
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
            ("ASR final fallback and text correction preserve normal Chinese terms", {
                try check(CloudRecognitionResultResolver.best(cloudText: "最终结果", latestPartial: "临时") == "最终结果", "Final lost")
                for final: String? in [nil, " \n"] {
                    try check(CloudRecognitionResultResolver.best(cloudText: final, latestPartial: "临时") == "临时", "Partial lost on empty final")
                }
                let text = "我们的愿景是开放源码，同时记录地图经纬度和老虎的踪迹。"
                try check(SpeechPostProcessor.postProcess(text) == text, "Normal terms corrupted")
                try check(SpeechPostProcessor.postProcess("这个八哥要调用阿皮哎") == "这个bug要调用API", "Terminology correction failed")
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
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure(description: "Cannot allocate UI bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure(description: "Cannot encode UI bitmap") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            panel.orderOut(nil)
            print("Rendered: \(name) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
        }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try render(ContentView(onOpenSettings: { _ in }, modes: fixture.modes, connections: fixture.connections, defaults: fixture.defaults),
                       name: "menu-\(theme)", size: NSSize(width: 380, height: 480), dark: dark)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, initialSection: .modes, defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "modes-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, initialSection: .models, defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "models-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            fixture.defaults.set(SpeechRecognitionProvider.cloud.rawValue, forKey: "speechRecognitionProvider")
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, initialSection: .speech,
                                    defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "speech-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            fixture.defaults.set("领域：合成测试。表达习惯：简洁直接。", forKey: PersonalContextStore.contextKey)
            try render(SettingsView(modes: fixture.modes, connections: fixture.connections, initialSection: .context,
                                    defaults: fixture.defaults, speechDependencies: fixture.speechSettings),
                       name: "context-\(theme)", size: NSSize(width: 1000, height: 740), dark: dark)
            let vm = RecordingViewModel(snapshotProvider: { throw TestFailure(description: "Preview cannot process") }, modeNameProvider: { "AI 指令" }, stopCapture: {}, cancelCapture: {})
            vm.isRecording = true; vm.isCaptureReady = true; vm.showsModes = true
            vm.statusText = "这是一段合成语音，用于界面检查。"
            try render(RecordingPanelView(viewModel: vm, modes: fixture.modes), name: "recording-\(theme)",
                       size: NSSize(width: 420, height: vm.panelHeight), dark: dark)
        }
        try render(SettingsView(modes: fixture.modes, connections: fixture.connections, defaults: fixture.defaults), name: "settings-minimum",
                   size: NSSize(width: 820, height: 580), dark: false)
        if let frontmost, let after = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            try check(after == frontmost, "Preview panels stole foreground application focus")
            print("PASS: Preview panels preserved foreground application focus")
        } else {
            print("SKIP: Foreground focus could not be read in this environment; interactive verification remains required")
        }
        print("PASS: Native light/dark/minimum-size surfaces rendered")
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

    private var speechDependencies: SpeechSettingsDependencies {
        var value = fixture.speechSettings
        value.readKey = {
            if failSpeechKeyRead { throw ConfigurationError.unavailable("合成测试：钥匙串暂不可读") }
            return "synthetic-speech-key"
        }
        value.saveKey = { _ in !failWrites }
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本地冒烟").font(.headline)
                Text("仅合成数据 · 模拟请求").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showMenu ? "返回设置" : "模式面板") { showMenu.toggle(); showingRecording = false }
                Button("模拟录音浮窗", action: showRecording)
                Toggle("模拟保存失败", isOn: $failWrites).toggleStyle(.checkbox)
                Toggle("模拟语音密钥读取失败", isOn: $failSpeechKeyRead).toggleStyle(.checkbox)
            }.padding(12)
            Divider()
            if showingRecording, let recordingModel {
                VStack(spacing: 16) {
                    Text("录音浮窗组件 · 嵌入测试窗口，不验证跨应用焦点")
                        .font(.caption).foregroundStyle(.secondary)
                    RecordingPanelView(viewModel: recordingModel, modes: fixture.modes).frame(width: 420)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showMenu {
                ContentView(onOpenSettings: { section in settingsSection = section; showMenu = false },
                            modes: fixture.modes, connections: fixture.connections, defaults: fixture.defaults)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsView(modes: fixture.modes, connections: fixture.connections, initialSection: settingsSection,
                             defaults: fixture.defaults, speechDependencies: speechDependencies, connectionTestService: service)
            }
            Divider()
            HStack {
                Text("模拟输出：" + output).font(.caption).textSelection(.enabled)
                Spacer()
                if let recordingModel { Button("完成合成语音") { recordingModel.stopRecording() } }
            }.padding(10)
        }
        .onChange(of: failWrites) { _, failing in fixture.failingFiles = failing ? ["modes", "connections"] : [] }
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
