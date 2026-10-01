import Foundation

/// Compatibility path for /audio/transcriptions. Audio stays in memory until recording ends.
/// This adapter does not claim live partial results or a verified connection during capture.
final class HTTPTranscriptionProvider: NSObject, CloudSpeechProvider, URLSessionTaskDelegate, @unchecked Sendable {
    let snapshot: SpeechSessionSnapshot
    private let configuration: URLSessionConfiguration
    private let lock = NSRecursiveLock()
    private var state: CloudConnectionState = .idle
    private var generation = UUID()
    private var audio = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var final: ((String) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var finishing = false
    var providerId: String { snapshot.connection.id }
    var displayName: String { snapshot.connection.name }
    var connectionState: CloudConnectionState { lock.lock(); defer { lock.unlock() }; return state }
    var isReady: Bool { connectionState == .connected }
    var onConnectionStateChanged: ((CloudConnectionState) -> Void)?
    init(snapshot: SpeechSessionSnapshot, configuration: URLSessionConfiguration = .ephemeral) {
        self.snapshot = snapshot; self.configuration = configuration
        super.init()
    }
    func connect(apiKey: String?, model: String, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        lock.lock(); defer { lock.unlock() }
        disconnect(); generation = UUID(); let id = generation
        final = onFinal; errorCallback = onError
        do {
            try SpeechConnectionStore.validate(snapshot.connection, credentials: snapshot.credentials)
            state = .connected
            DispatchQueue.main.async { [weak self] in
                guard let self, self.matches(id) else { return }; self.onConnectionStateChanged?(.connected)
            }
        } catch {
            state = .failed(error.localizedDescription)
            DispatchQueue.main.async { [weak self] in guard let self, self.matches(id) else { return }; onError(error) }
        }
    }
    private func matches(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == id }
    func sendAudio(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard state == .connected, !finishing else { return }
        guard data.count % 2 == 0, audio.count + data.count <= 24_000_000 else {
            state = .failed("音频超过自定义接口的 24 MB 上限"); audio.removeAll()
            let callback = errorCallback, id = generation
            DispatchQueue.main.async { [weak self] in guard let self, self.matches(id) else { return }; callback?(CloudSpeechError.apiError("音频超过 24 MB，请分段录音")) }; return
        }
        audio.append(data)
    }
    func finish(completion: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard state == .connected, !finishing else { DispatchQueue.main.async { completion(nil) }; return }
        finishing = true
        let id = generation
        guard !audio.isEmpty else {
            state = .disconnected
            DispatchQueue.main.async { [weak self] in
                guard let self, self.matches(id) else { return }
                self.onConnectionStateChanged?(.disconnected); completion("")
            }
            return
        }
        do {
            let request = try Self.request(snapshot: snapshot, pcm: audio)
            audio.removeAll()
            let configuration = self.configuration.copy() as! URLSessionConfiguration
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil); self.session = session
            task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self, self.matches(id) else { return }
                let result: Result<String, Error>
                if error != nil { result = .failure(CloudSpeechError.apiError("音频转写请求失败或超时")) }
                else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                        let data, data.count <= 4_000_000,
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result = .success(text)
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    result = .failure(CloudSpeechError.apiError("音频转写未返回有效正文（HTTP \(status)）"))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.matches(id) else { return }
                    self.lock.lock(); self.task = nil; self.session?.finishTasksAndInvalidate(); self.session = nil
                    switch result {
                    case .success: self.state = .disconnected
                    case .failure(let error): self.state = .failed(error.localizedDescription)
                    }
                    self.lock.unlock()
                    self.onConnectionStateChanged?(self.connectionState)
                    switch result {
                    case .success(let text): self.final?(text); completion(text)
                    case .failure(let error): self.errorCallback?(error); completion(nil)
                    }
                }
            }
            task?.resume()
        } catch { let callback = errorCallback; DispatchQueue.main.async { [weak self] in guard let self, self.matches(id) else { return }; callback?(error); completion(nil) } }
    }
    static func request(snapshot: SpeechSessionSnapshot, pcm: Data, boundary: String = "Spoken-" + UUID().uuidString) throws -> URLRequest {
        try SpeechConnectionStore.validate(snapshot.connection, credentials: snapshot.credentials)
        guard let url = URL(string: snapshot.connection.endpoint) else { throw CloudSpeechError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer \(snapshot.credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", snapshot.connection.model); field("response_format", "json")
        if !snapshot.connection.language.isEmpty { field("language", snapshot.connection.language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm)); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = body
        return request
    }
    static func wav(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        u32(UInt32(pcm.count) + 36); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); data.append(Data("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); task?.cancel(); session?.invalidateAndCancel(); session = nil; task = nil
        audio.removeAll(); final = nil; errorCallback = nil; state = .idle; finishing = false
    }
    func preconnect() {}
    func cancelPreconnect() {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
