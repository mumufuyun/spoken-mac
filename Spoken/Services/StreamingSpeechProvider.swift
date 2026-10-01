import Foundation

protocol SpeechSocket: AnyObject {
    func open(_ request: URLRequest, completion: @escaping (Result<Void, Error>) -> Void)
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void)
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func close()
}

final class URLSessionSpeechSocket: NSObject, SpeechSocket, URLSessionWebSocketDelegate {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opened: ((Result<Void, Error>) -> Void)?
    func open(_ request: URLRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        opened = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session?.webSocketTask(with: request)
        let task = self.task
        task?.maximumMessageSize = 4_000_000
        lock.unlock()
        task?.resume()
    }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        lock.lock(); let task = self.task; lock.unlock()
        guard let task else { completion(CloudSpeechError.connectionFailed); return }
        task.send(message, completionHandler: completion)
    }
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.lock(); let task = self.task; lock.unlock()
        guard let task else { completion(.failure(CloudSpeechError.connectionFailed)); return }
        task.receive(completionHandler: completion)
    }
    func close() {
        lock.lock()
        let task = self.task, session = self.session
        opened = nil; self.task = nil; self.session = nil
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        let callback = self.task === webSocketTask ? opened : nil
        if self.task === webSocketTask { opened = nil }
        lock.unlock()
        callback?(.success(()))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let callback = self.task === task ? opened : nil
        if self.task === task { opened = nil }
        lock.unlock()
        callback?(.failure(error))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Serial, bounded and paced streaming. Each instance belongs to exactly one connection snapshot.
final class StreamingSpeechProvider: CloudSpeechProvider, @unchecked Sendable {
    let snapshot: SpeechSessionSnapshot
    private let makeSocket: () -> SpeechSocket
    private let queue = DispatchQueue(label: "com.moss.spoken.asr-stream")
    private let queueKey = DispatchSpecificKey<Void>()
    private var socket: SpeechSocket?
    private var codec: SpeechWireProtocol
    private var generation = UUID()
    private var state: CloudConnectionState = .idle
    private var stateCallback: ((CloudConnectionState) -> Void)?
    private var partial: ((String) -> Void)?
    private var final: ((String) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var finished: ((String?) -> Void)?
    private var pending = Data()
    private var latest = ""
    private var sessionID = ""
    private var finishing = false
    private var ended = false
    private var sending = false
    private var sentAudio = false
    private var sentEnd = false
    private var timer: DispatchSourceTimer?
    private var deadline: DispatchWorkItem?
    private let setupTimeout: TimeInterval
    private let finalTimeout: TimeInterval
    var providerId: String { snapshot.connection.id }
    var displayName: String { snapshot.connection.name }
    var connectionState: CloudConnectionState { sync { state } }
    var isReady: Bool { connectionState == .connected }
    var onConnectionStateChanged: ((CloudConnectionState) -> Void)? {
        get { sync { stateCallback } }
        set { queue.async { self.stateCallback = newValue } }
    }
    init(snapshot: SpeechSessionSnapshot, makeSocket: @escaping () -> SpeechSocket = { URLSessionSpeechSocket() }, setupTimeout: TimeInterval = 15, finalTimeout: TimeInterval = 15) {
        self.snapshot = snapshot; self.makeSocket = makeSocket; codec = SpeechWireProtocol(snapshot)
        self.setupTimeout = setupTimeout; self.finalTimeout = finalTimeout
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { timer?.cancel(); deadline?.cancel(); socket?.close() }
    private func sync<T>(_ block: () -> T) -> T { DispatchQueue.getSpecific(key: queueKey) != nil ? block() : queue.sync(execute: block) }
    private func publish(_ value: CloudConnectionState) {
        state = value; let id = generation; let callback = stateCallback
        DispatchQueue.main.async { [weak self] in guard let self, self.sync({ self.generation == id }) else { return }; callback?(value) }
    }
    func connect(apiKey: String?, model: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        queue.async {
            self.clear(); self.generation = UUID(); let id = self.generation
            self.codec = SpeechWireProtocol(self.snapshot); self.partial = onPartial; self.final = onFinal; self.errorCallback = onError
            self.publish(.connecting)
            do {
                let request = try self.codec.request()
                let socket = self.makeSocket(); self.socket = socket
                self.armTimeout(self.setupTimeout, error: .sessionSetupTimeout)
                socket.open(request) { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        guard self.generation == id, !self.ended else { return }
                        switch result {
                        case .failure: self.fail(CloudSpeechError.connectionFailed)
                        case .success:
                            self.receive(id)
                            do {
                                if let frame = try self.codec.initialFrame() {
                                    socket.send(frame) { [weak self] error in
                                        guard let self else { return }
                                        self.queue.async {
                                            guard self.generation == id, !self.ended else { return }
                                            if error != nil { self.fail(CloudSpeechError.connectionFailed) } else { self.ready() }
                                        }
                                    }
                                }
                            } catch { self.fail(error) }
                        }
                    }
                }
            } catch { self.fail(error) }
        }
    }
    private func ready() {
        guard state != .connected else { return }
        deadline?.cancel(); deadline = nil; publish(.connected)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: codec.frameInterval)
        timer.setEventHandler { [weak self] in self?.pump() }; timer.resume(); self.timer = timer
        if finishing { armTimeout(Double(pending.count) / 32_000 + finalTimeout, error: .timeout) }
    }
    func sendAudio(_ data: Data) {
        queue.async {
            guard !self.ended, !self.finishing, self.socket != nil else { return }
            guard data.count % 2 == 0, self.pending.count + data.count <= 960_000 else {
                self.fail(CloudSpeechError.apiError("音频缓冲超限，请检查网络后重新录音")); return
            }
            self.pending.append(data)
        }
    }
    private func pump() {
        guard state == .connected, !ended, !sending, let socket else { return }
        let id = generation
        let message: URLSessionWebSocketTask.Message
        if pending.count >= codec.frameBytes || (finishing && !pending.isEmpty) {
            let count = min(codec.frameBytes, pending.count)
            let chunk = Data(pending.prefix(count)); pending.removeFirst(count)
            message = codec.audioFrame(chunk); sentAudio = true
        } else if finishing {
            timer?.cancel(); timer = nil
            guard sentAudio else { succeed(""); return }
            do { message = try codec.endFrame(sessionID: sessionID) } catch { fail(error); return }
            sentEnd = true
        } else { return }
        sending = true
        socket.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == id, !self.ended else { return }
                self.sending = false
                if error != nil { self.fail(CloudSpeechError.connectionFailed) }
            }
        }
    }
    private func receive(_ id: UUID) {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.generation == id, !self.ended else { return }
                switch result {
                case .failure: self.fail(CloudSpeechError.connectionFailed)
                case .success(let message):
                    do {
                        let event = try self.codec.parse(message)
                        if let sessionID = event.sessionID { self.sessionID = sessionID }
                        if event.ready { self.ready() }
                        if let text = event.text {
                            self.latest = text; let partial = self.partial
                            DispatchQueue.main.async { [weak self] in guard let self, self.sync({ self.generation == id }) else { return }; partial?(text) }
                        }
                        if event.final {
                            if self.finishing && self.sentEnd { self.succeed(self.latest) }
                            else { self.fail(CloudSpeechError.apiError("供应商提前结束识别，请重新录音")) }
                        } else { self.receive(id) }
                    } catch { self.fail(error) }
                }
            }
        }
    }
    func finish(completion: @escaping (String?) -> Void) {
        queue.async {
            guard !self.ended, self.finished == nil else { DispatchQueue.main.async { completion(nil) }; return }
            self.finished = completion; self.finishing = true
            self.armTimeout(Double(self.pending.count) / 32_000 + self.finalTimeout, error: .timeout)
        }
    }
    private func succeed(_ text: String) {
        ended = true; deadline?.cancel(); timer?.cancel(); socket?.close(); socket = nil
        publish(.disconnected)
        pending.removeAll(); let final = self.final, completion = finished, id = generation; finished = nil
        DispatchQueue.main.async { [weak self] in guard let self, self.sync({ self.generation == id }) else { return }; final?(text); completion?(text) }
    }
    private func fail(_ error: Error) {
        guard !ended else { return }
        ended = true; deadline?.cancel(); timer?.cancel(); socket?.close(); socket = nil; pending.removeAll()
        publish(.failed(error.localizedDescription))
        let callback = errorCallback, completion = finished, id = generation; finished = nil
        DispatchQueue.main.async { [weak self] in guard let self, self.sync({ self.generation == id }) else { return }; callback?(error); completion?(nil) }
    }
    private func armTimeout(_ seconds: TimeInterval, error: CloudSpeechError) {
        deadline?.cancel(); let id = generation
        let item = DispatchWorkItem { [weak self] in guard let self, self.generation == id, !self.ended else { return }; self.fail(error) }
        deadline = item; queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func clear() {
        timer?.cancel(); timer = nil; deadline?.cancel(); deadline = nil; socket?.close(); socket = nil
        pending.removeAll(); latest = ""; sessionID = ""; finishing = false; ended = false; sending = false; sentAudio = false; sentEnd = false
        partial = nil; final = nil; errorCallback = nil; finished = nil
    }
    func disconnect() { queue.async { self.generation = UUID(); self.clear(); self.publish(.idle) } }
    // Opening these services starts a billable session. Do not preconnect while idle.
    func preconnect() {}
    func cancelPreconnect() {}
}
