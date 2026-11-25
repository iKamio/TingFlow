import Foundation
import CommonCrypto

/// Synthetic URLProtocol only; every URL is intercepted, including unexpected requests.
final class NeteaseQualityFixture: URLProtocol, @unchecked Sendable {
    enum Reply { case row([String: Any]), business(Int), http(Int), transport(URLError.Code) }
    private static let lock = NSLock()
    private static var v1: [Reply] = []
    private static var legacy: [Reply] = []
    private static var records: [(String, [String: Any])] = []
    private static var avatar = "http://p1.music.126.net/fixture-avatar.jpg"
    static func configure(_ replies: [Reply], legacy fallback: [Reply] = [], avatarURL: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        v1 = replies; legacy = fallback; records = []
        if let avatarURL { avatar = avatarURL }
    }
    static func requests() -> [(String, [String: Any])] {
        lock.lock(); defer { lock.unlock() }; return records
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, NeteaseWire.isAPIURL(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let path = url.path
        var object: [String: Any] = ["code": 200]
        var status = 200
        var responseBody: Data?
        if url == NeteaseWire.xeapiKeyURL {
            do { responseBody = try NeteaseXEAPIServerFixture.keyResponse(request) }
            catch { client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData)); return }
        } else if path.contains("/song/enhance/player/url") {
            let payload = path.hasPrefix("/xeapi/") ? NeteaseXEAPIServerFixture.openPayload(request) : [:]
            Self.lock.lock()
            Self.records.append((path, payload))
            let reply: Reply
            if path.hasSuffix("/v1"), !Self.v1.isEmpty { reply = Self.v1.removeFirst() }
            else if !path.hasSuffix("/v1"), !Self.legacy.isEmpty { reply = Self.legacy.removeFirst() }
            else { reply = .http(418) } // No infinite retries hidden by a successful default.
            Self.lock.unlock()
            switch reply {
            case .row(let row):
                object["data"] = [row]
                if path.hasPrefix("/xeapi/") { responseBody = NeteaseXEAPIServerFixture.encryptedResponse(object) }
            case .business(let code): object["code"] = code
            case .http(let code): status = code
            case .transport(let code): client?.urlProtocol(self, didFailWithError: URLError(code)); return
            }
        } else {
            switch path {
            case "/eapi/nuser/account/get":
                Self.lock.lock(); let avatar = Self.avatar; Self.lock.unlock()
                object["account"] = ["id": 7]
                object["profile"] = ["userId": 7, "nickname": "Quality fixture", "avatarUrl": avatar]
            case "/eapi/user/playlist": object["playlist"] = []; object["more"] = false
            case "/eapi/v3/discovery/recommend/songs": object["data"] = ["dailySongs": []]
            case "/eapi/v1/discovery/recommend/resource": object["recommend"] = []
            case "/eapi/personalized/playlist": object["result"] = []
            default: status = 418
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody ?? (try! JSONSerialization.data(withJSONObject: object)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }

    private static func openEAPI(_ request: URLRequest) -> [String: Any] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems
        guard let hex = fields?.first(where: { $0.name == "params" })?.value else { return [:] }
        let chars = Array(hex), key = Array("e82ckenh8dichen8".utf8)
        guard chars.count % 2 == 0 else { return [:] }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return [:] }; bytes.append(byte)
        }
        var output = [UInt8](repeating: 0, count: bytes.count + 16), length = 0
        let capacity = output.count
        let result = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key, key.count, nil,
            bytes, bytes.count, &output, capacity, &length)
        guard result == kCCSuccess else { return [:] }
        let parts = String(decoding: output.prefix(length), as: UTF8.self).components(separatedBy: "-36cd479b6b5-")
        guard parts.count == 3, parts[0] == "/api/song/enhance/player/url/v1",
              let data = parts[1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
