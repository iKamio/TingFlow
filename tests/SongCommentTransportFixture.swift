import Foundation
import CommonCrypto

// This executable never links the real Keychain wrapper.
@MainActor enum SecureVault {
    static var values: [String: Data] = [:]
    static var reads = 0
    static var writes = 0
    static func read(key: String) throws -> Data? { reads += 1; return values[key] }
    static func save(_ data: Data, key: String) throws { writes += 1; values[key] = data }
    static func remove(key: String) throws { values.removeValue(forKey: key) }
}
final class SongCommentTransportFixture: URLProtocol, @unchecked Sendable {
    enum Mode { case normal, signedOut, verification, rateLimited, malformed, httpFailure, oversized, hold }
    struct Read {
        let url: URL
        let authenticated: Bool
        let threadID: String?
        let sort: Int?
        let page: Int?
        let cursor: String?
    }
    private static let lock = NSLock()
    private static var mode = Mode.normal
    private static var records: [Read] = []
    private static var stops = 0
    static func configure(_ value: Mode) { lock.lock(); mode = value; records = []; stops = 0; lock.unlock() }
    static func requested() -> [Read] { lock.lock(); defer { lock.unlock() }; return records }
    static func stopCount() -> Int { lock.lock(); defer { lock.unlock() }; return stops }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func payload() -> [String: Any] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < 100_000 {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }; body.append(contentsOf: buffer.prefix(size))
            }
        }
        guard let form = String(data: body, encoding: .utf8), form.hasPrefix("params="),
              let hex = String(form.dropFirst(7)).removingPercentEncoding, hex.count % 2 == 0 else { return [:] }
        var bytes: [UInt8] = []; var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<end], radix: 16) else { return [:] }
            bytes.append(value); index = end
        }
        let key = Array("e82ckenh8dichen8".utf8)
        var output = [UInt8](repeating: 0, count: bytes.count + 16), size = 0
        let capacity = output.count
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                             key, key.count, nil, bytes, bytes.count, &output, capacity, &size)
        guard status == kCCSuccess, let text = String(bytes: output.prefix(size), encoding: .utf8) else { return [:] }
        let parts = text.components(separatedBy: "-36cd479b6b5-")
        guard parts.count == 3, let data = parts[1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    override func startLoading() {
        guard let url = request.url, NeteaseWire.isAPIURL(url), request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let comment = url.path == "/eapi/v2/resource/comments"
        let fields = comment ? payload() : [:]
        Self.lock.lock()
        let current = Self.mode
        if comment {
            Self.records.append(Read(url: url, authenticated: request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=") == true,
                                     threadID: fields["threadId"] as? String, sort: fields["sortType"] as? Int,
                                     page: fields["pageNo"] as? Int, cursor: fields["cursor"] as? String))
        }
        Self.lock.unlock()
        var root: [String: Any] = ["code": 200]
        if comment {
            if current == .hold { return }
            switch current {
            case .signedOut: root = ["code": 301]
            case .verification: root = ["code": -460]
            case .rateLimited: root = ["code": 429]
            case .malformed: root = ["code": 200, "data": ["comments": "changed contract"]]
            default: root = SongCommentFixture.root([SongCommentFixture.row("1")], total: 1, more: false)
            }
        } else {
            switch url.path {
            case "/eapi/nuser/account/get": root["account"] = ["id": 7]; root["profile"] = ["userId": 7, "nickname": "Synthetic account"]
            case "/eapi/user/playlist": root["more"] = false; root["playlist"] = []
            case "/eapi/v3/discovery/recommend/songs": root["data"] = ["dailySongs": []]
            case "/eapi/v1/discovery/recommend/resource": root["recommend"] = []
            case "/eapi/personalized/playlist": root["result"] = []
            default: root = ["code": 404]
            }
        }
        var headers = ["Content-Type": "application/json"]
        if comment {
            headers["Set-Cookie"] = "MUSIC_U=synthetic-unwanted-comment-cookie; Domain=.music.163.com; Path=/; HttpOnly"
            if current == .oversized { headers["Content-Length"] = "2000001" }
        }
        let status = comment && current == .httpFailure ? 503 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: root)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
}
