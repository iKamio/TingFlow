import Foundation
import CommonCrypto

// Own executable only; never link NeteaseFlowFixture or the production Keychain wrapper.
@MainActor enum SecureVault {
    static var values: [String: Data] = [:]
    static func save(_ data: Data, key: String) throws { values[key] = data }
    static func read(key: String) throws -> Data? { values[key] }
    static func remove(key: String) throws { values.removeValue(forKey: key) }
}

/// All URLs are intercepted. Synthetic credentials only; payloads never printed.
final class NeteaseCloudFixture: URLProtocol, @unchecked Sendable {
    enum Fault { case none, timeoutAfterApply, readDenyAfterApply, mismatchAfterApply, risk, duplicate512, http503AfterApply, holdReadAfterApply }
    struct Record { let path: String; let payload: [String: Any]; let safeWire: Bool }
    private static let lock = NSLock()
    private static var likes: Set<String> = []
    private static var subscriptions: Set<String> = ["102"]
    private static var tracks: [String: Set<String>] = ["101": ["1"], "102": [], "103": [], "104": []]
    private static var records: [Record] = []
    private static var fault: Fault = .none
    private static var denyRead = false
    private static var heldRead: NeteaseCloudFixture?
    private static var holdNext = false
    private var stopped = false
    static func configure(_ value: Fault = .none) { lock.lock(); fault = value; denyRead = false; lock.unlock() }
    static func requests() -> [Record] { lock.lock(); defer { lock.unlock() }; return records }
    static func holdLikes() { lock.lock(); holdNext = true; lock.unlock() }
    static func hasHeldRead() -> Bool { lock.lock(); defer { lock.unlock() }; return heldRead != nil }
    static func releaseRead() {
        lock.lock(); let pending = heldRead; heldRead = nil; lock.unlock()
        pending?.reply(["code": 200, "ids": ["777"]])
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func isWrite(_ path: String) -> Bool {
        ["/eapi/radio/like", "/eapi/playlist/subscribe", "/eapi/playlist/unsubscribe", "/eapi/playlist/manipulate/tracks", "/eapi/feedback/weblog"].contains(path)
    }
    private static func playlist(_ id: String) -> [String: Any] {
        let own = id == "101" || id == "104"
        let ids = (tracks[id] ?? []).sorted()
        return ["id": id, "name": "Fixture list", "creator": ["userId": own ? "7" : "8", "nickname": "Synthetic owner"],
                "privacy": own ? 10 : 0, "trackCount": ids.count, "trackIds": ids.map { ["id": $0] }]
    }
    override func startLoading() {
        guard let url = request.url, NeteaseWire.isAPIURL(url), url.host == "interface.music.163.com", url.path.hasPrefix("/eapi/") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let payload = Self.openEAPI(request), path = url.path
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let forbidden = ["fixture-extra", "OTHER_SECRET", "unrelated-cookie"]
        let safe = request.httpMethod == "POST" && url.query == nil && !payload.isEmpty &&
            !forbidden.contains(where: { cookie.contains($0) }) && request.httpShouldHandleCookies == false
        var object: [String: Any] = ["code": 200], status = 200
        Self.lock.lock()
        Self.records.append(Record(path: path, payload: payload, safeWire: safe))
        if path == "/eapi/song/like/get", Self.holdNext {
            Self.holdNext = false; Self.heldRead = self; Self.lock.unlock(); return
        }
        let isWrite = Self.isWrite(path), fault = Self.fault
        if isWrite { Self.fault = .none }
        if isWrite && (fault == .risk || fault == .duplicate512) {
            Self.lock.unlock(); reply(["code": fault == .risk ? -462 : 512, "message": "never-show-fixture-private-body"]); return
        }
        switch path {
        case "/eapi/nuser/account/get":
            object["account"] = ["id": 7]; object["profile"] = ["userId": 7, "nickname": "Cloud fixture"]
        case "/eapi/user/playlist":
            object["playlist"] = (["101", "104"] + Self.subscriptions.sorted()).map(Self.playlist)
            object["more"] = false
        case "/eapi/v3/discovery/recommend/songs": object["data"] = ["dailySongs": []]
        case "/eapi/v1/discovery/recommend/resource": object["recommend"] = []
        case "/eapi/personalized/playlist": object["result"] = []
        case "/eapi/song/like/get": object["ids"] = Self.likes.sorted()
        case "/eapi/radio/like":
            if let id = payload["trackId"] as? String, fault != .mismatchAfterApply {
                if payload["like"] as? String == "true" { Self.likes.insert(id) } else { Self.likes.remove(id) }
            }
        case "/eapi/playlist/subscribe": if let id = payload["id"] as? String { Self.subscriptions.insert(id) }
        case "/eapi/playlist/unsubscribe": if let id = payload["id"] as? String { Self.subscriptions.remove(id) }
        case "/eapi/v6/playlist/detail":
            if let id = payload["id"] as? String { object["playlist"] = Self.playlist(id) }
        case "/eapi/playlist/manipulate/tracks":
            if let id = payload["pid"] as? String, let text = payload["trackIds"] as? String,
               let data = text.data(using: .utf8), let ids = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                for value in ids { if let song = NeteaseMapping.id(value) { Self.tracks[id, default: []].insert(song) } }
            }
        case "/eapi/v3/song/detail": object["songs"] = [["id": 1, "name": "Fixture song"]]
        case "/eapi/play-record/song/list":
            object["data"] = ["list": [["data": ["id": 11, "name": "History fixture", "ar": [["name": "Artist"]], "dt": 120000], "resourceId": "11", "playTime": 1700000000000 as Int64]]]
        case "/eapi/feedback/weblog": break
        default: status = 418
        }
        if isWrite && fault == .readDenyAfterApply { Self.denyRead = true }
        if isWrite && fault == .holdReadAfterApply { Self.holdNext = true }
        if !isWrite && Self.denyRead { object = ["code": -462, "message": "never-show-fixture-private-body"] }
        Self.lock.unlock()
        if isWrite && fault == .timeoutAfterApply { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if isWrite && fault == .http503AfterApply { status = 503 }
        reply(object, status: status)
    }
    private func reply(_ object: [String: Any], status: Int = 200) {
        Self.lock.lock(); let stopped = self.stopped; Self.lock.unlock()
        guard !stopped, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }

    private static func openEAPI(_ request: URLRequest) -> [String: Any] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n))
                if body.count > 1_000_000 { return [:] }
            }
        }
        let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems
        guard let hex = fields?.first(where: { $0.name == "params" })?.value else { return [:] }
        let chars = Array(hex), key = Array("e82ckenh8dichen8".utf8)
        guard chars.count % 2 == 0 else { return [:] }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return [:] }
            bytes.append(byte)
        }
        var output = [UInt8](repeating: 0, count: bytes.count + 16), length = 0
        let capacity = output.count
        let result = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key, key.count, nil,
            bytes, bytes.count, &output, capacity, &length)
        guard result == kCCSuccess else { return [:] }
        let parts = String(decoding: output.prefix(length), as: UTF8.self).components(separatedBy: "-36cd479b6b5-")
        guard parts.count == 3, let url = request.url,
              parts[0] == "/api/" + url.path.dropFirst("/eapi/".count),
              let data = parts[1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
