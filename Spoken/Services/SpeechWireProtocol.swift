import Foundation
import CryptoKit

/// Pure request/response codecs. Never log signed URLs, credentials, audio or transcripts.
struct SpeechWireEvent {
    var ready = false
    var sessionID: String?
    var text: String?
    var final = false
}

struct SpeechWireProtocol {
    let snapshot: SpeechSessionSnapshot
    private var segments: [Int: String] = [:]
    private var confirmedSegments = Set<Int>()
    private var lastVolcSequence: Int32 = 0

    init(_ snapshot: SpeechSessionSnapshot) { self.snapshot = snapshot }
    var frameBytes: Int { snapshot.connection.api == .iflytekRealtime ? 1280 : 6400 }
    var frameInterval: TimeInterval { Double(frameBytes) / 32_000 }

    func request(now: Date = Date(), requestID: String = UUID().uuidString) throws -> URLRequest {
        let c = snapshot.connection, secret = snapshot.credentials
        try SpeechConnectionStore.validate(c, credentials: secret)
        guard var parts = URLComponents(string: c.endpoint) else { throw CloudSpeechError.invalidURL }
        var request: URLRequest
        if c.api == .iflytekRealtime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            var values = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
            values.merge(["appId": c.appID, "accessKeyId": secret.apiKey, "uuid": requestID,
                          "utc": formatter.string(from: now), "lang": c.language,
                          "audio_encode": "pcm_s16le", "samplerate": "16000"], uniquingKeysWith: { _, new in new })
            let unsigned = Self.query(values)
            let signature = HMAC<Insecure.SHA1>.authenticationCode(for: Data(unsigned.utf8), using: SymmetricKey(data: Data(secret.apiSecret.utf8)))
            values["signature"] = Data(signature).base64EncodedString()
            parts.percentEncodedQuery = Self.query(values)
            guard let url = parts.url else { throw CloudSpeechError.invalidURL }
            request = URLRequest(url: url)
        } else {
            guard let url = parts.url else { throw CloudSpeechError.invalidURL }
            request = URLRequest(url: url)
            request.setValue(secret.apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(c.model, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        }
        request.timeoutInterval = 15
        return request
    }
    private static func query(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
    }
    func initialFrame() throws -> URLSessionWebSocketTask.Message? {
        guard snapshot.connection.api == .volcengineStreaming else { return nil }
        let body: [String: Any] = ["user": ["uid": UUID().uuidString],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "result_type": "full"]]
        return .data(Self.volcFrame(type: 1, flags: 0, serialization: 1, payload: try JSONSerialization.data(withJSONObject: body)))
    }
    func audioFrame(_ data: Data) -> URLSessionWebSocketTask.Message {
        snapshot.connection.api == .iflytekRealtime ? .data(data) : .data(Self.volcFrame(type: 2, flags: 0, serialization: 0, payload: data))
    }
    func endFrame(sessionID: String) throws -> URLSessionWebSocketTask.Message {
        if snapshot.connection.api == .iflytekRealtime {
            guard !sessionID.isEmpty else { throw CloudSpeechError.sessionSetupTimeout }
            return .string(String(decoding: try JSONSerialization.data(withJSONObject: ["end": true, "sessionId": sessionID]), as: UTF8.self))
        }
        return .data(Self.volcFrame(type: 2, flags: 2, serialization: 0, payload: Data()))
    }
    static func volcFrame(type: UInt8, flags: UInt8, serialization: UInt8, payload: Data) -> Data {
        var result = Data([0x11, type << 4 | flags, serialization << 4, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }; result.append(payload)
        return result
    }
    mutating func parse(_ message: URLSessionWebSocketTask.Message) throws -> SpeechWireEvent {
        let bytes: Data
        switch message { case .string(let s): bytes = Data(s.utf8); case .data(let data): bytes = data; @unknown default: throw CloudSpeechError.apiError("不支持的响应类型") }
        guard bytes.count <= 4_000_000 else { throw CloudSpeechError.apiError("识别响应过大") }
        if snapshot.connection.api == .iflytekRealtime { return try parseIflytek(bytes) }
        return try parseVolc(bytes)
    }
    private mutating func parseIflytek(_ bytes: Data) throws -> SpeechWireEvent {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CloudSpeechError.apiError("讯飞响应格式无效") }
        let code = (object["code"] as? String) ?? (object["code"] as? NSNumber)?.stringValue ?? "0"
        guard code == "0", object["action"] as? String != "error" else { throw CloudSpeechError.apiError("讯飞返回错误码 \(code)") }
        var data = object["data"] as? [String: Any] ?? [:]
        if let encoded = object["data"] as? String, let bytes = encoded.data(using: .utf8), !bytes.isEmpty {
            data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
        }
        if let session = data["sessionId"] as? String, !session.isEmpty, object["msg_type"] as? String == "action" {
            return SpeechWireEvent(ready: true, sessionID: session)
        }
        if object["action"] as? String == "started", let sid = object["sid"] as? String, !sid.isEmpty {
            return SpeechWireEvent(ready: true, sessionID: sid)
        }
        if object["res_type"] as? String == "frc", data["normal"] as? Bool == false { throw CloudSpeechError.apiError("讯飞识别会话异常") }
        let final = data["ls"] as? Bool == true
        guard let cn = data["cn"] as? [String: Any], let st = cn["st"] as? [String: Any], let rt = st["rt"] as? [[String: Any]],
              let id = data["seg_id"] as? Int else {
            if final { return SpeechWireEvent(text: transcript, final: true) }
            return SpeechWireEvent()
        }
        let text = rt.flatMap { $0["ws"] as? [[String: Any]] ?? [] }.compactMap { item in
            (item["cw"] as? [[String: Any]])?.first?["w"] as? String
        }.joined()
        let type = (st["type"] as? String) ?? (st["type"] as? NSNumber)?.stringValue
        if !confirmedSegments.contains(id) || type == "0" {
            segments[id] = text
            if type == "0" { confirmedSegments.insert(id) }
        }
        return SpeechWireEvent(text: transcript, final: final)
    }
    private var transcript: String { segments.keys.sorted().compactMap { segments[$0] }.joined() }
    private mutating func parseVolc(_ bytes: Data) throws -> SpeechWireEvent {
        let b = [UInt8](bytes)
        guard b.count >= 8, b[0] >> 4 == 1 else { throw CloudSpeechError.apiError("豆包响应头无效") }
        let header = Int(b[0] & 0x0f) * 4, type = b[1] >> 4, flags = b[1] & 0x0f
        guard header >= 4, b.count >= header + 4, b[2] & 0x0f == 0 else { throw CloudSpeechError.apiError("豆包响应编码与请求不一致") }
        func number(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= b.count else { throw CloudSpeechError.apiError("豆包响应被截断") }
            return b[offset..<offset+4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        if type == 15 { throw CloudSpeechError.apiError("豆包返回错误码 \(try number(header))") }
        guard type == 9, b[2] >> 4 == 1 else { throw CloudSpeechError.apiError("豆包响应类型无效") }
        var offset = header; var sequence: Int32?
        if flags & 1 != 0 { sequence = Int32(bitPattern: try number(offset)); offset += 4 }
        let length = Int(try number(offset)); offset += 4
        guard length <= 4_000_000, offset + length == b.count else { throw CloudSpeechError.apiError("豆包响应长度无效") }
        guard let object = try JSONSerialization.jsonObject(with: Data(b[offset...])) as? [String: Any] else { throw CloudSpeechError.apiError("豆包响应正文无效") }
        if let code = object["code"] as? Int, code != 0 && code != 1000 && code != 20000000 { throw CloudSpeechError.apiError("豆包返回错误码 \(code)") }
        if let sequence, sequence > 0 && sequence <= lastVolcSequence { return SpeechWireEvent() }
        if let sequence, sequence > 0 { lastVolcSequence = sequence }
        let result = object["result"] as? [String: Any] ?? (object["result"] as? [[String: Any]])?.first
        return SpeechWireEvent(text: result?["text"] as? String, final: flags & 2 != 0 || (sequence ?? 0) < 0)
    }
}
