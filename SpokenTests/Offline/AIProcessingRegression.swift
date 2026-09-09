import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
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
                let prompt = messages[0]["content"]!
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
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Offline AI checks: \(tests.count - failures)/\(tests.count) passed. No external model requests.")
        exit(failures == 0 ? 0 : 1)
    }
}
