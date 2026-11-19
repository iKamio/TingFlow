import Foundation

// Separate executable only: this test never links the production Keychain wrapper.
@MainActor enum SecureVault {
    static var values: [String: Data] = [:]
    static func save(_ data: Data, key: String) throws { values[key] = data }
    static func read(key: String) throws -> Data? { values[key] }
    static func remove(key: String) throws { values.removeValue(forKey: key) }
}

final class NeteaseFlowFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var paths: [String] = []
    private static var failingDaily = false
    static func failDaily(_ value: Bool) { lock.lock(); failingDaily = value; lock.unlock() }
    static func requested() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, NeteaseWire.isAPIURL(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.lock.lock(); Self.paths.append(url.path); let fail = Self.failingDaily; Self.lock.unlock()
        var object: [String: Any] = ["code": 200]
        var headers = ["Content-Type": "application/json"]
        switch url.path {
        case "/eapi/login/qrcode/unikey": object["unikey"] = "synthetic-key-not-real"
        case "/eapi/login/qrcode/client/login":
            object["code"] = 803
            headers["Set-Cookie"] = "MUSIC_U=fixture-session; Path=/; Domain=.music.163.com; HttpOnly, __csrf=fixture-csrf; Path=/; Domain=.music.163.com"
        case "/eapi/nuser/account/get": object["account"] = ["id": 7]; object["profile"] = ["userId": 7, "nickname": "Fixture account", "avatarUrl": "http://p1.music.126.net/fixture-avatar.jpg"]
        case "/eapi/user/playlist":
            object["more"] = false
            object["playlist"] = [
                ["id": 101, "name": "Private list", "trackCount": 3, "privacy": 10, "creator": ["userId": 7, "nickname": "Owner"]],
                ["id": 102, "name": "Subscribed", "trackCount": 10, "creator": ["userId": 8, "nickname": "Other"]]]
        case "/eapi/v3/discovery/recommend/songs":
            if fail { object = ["code": 400, "message": "private-secret-server-body"] }
            else { object["data"] = ["dailySongs": [["id": 1, "name": "Daily song", "dt": 1000, "al": ["id": 11, "name": "Album"], "ar": [["name": "Artist"]]]]] }
        case "/eapi/v1/discovery/recommend/resource": object["recommend"] = [["id": 201, "name": "Daily list", "trackCount": 2, "picUrl": "https://p1.music.126.net/fixture.jpg"]]
        case "/eapi/personalized/playlist": object["result"] = [["id": 301, "name": "Featured", "trackCount": 20]]
        case "/eapi/v1/radio/get": object["data"] = [["id": 5, "name": "FM", "duration": 2000, "album": ["name": "Legacy"], "artists": [["name": "Singer"]]]]
        case "/eapi/v6/playlist/detail": object["playlist"] = ["id": 101, "trackCount": 3, "trackIds": [["id": 2], ["id": 1], ["id": 2]]]
        case "/eapi/v3/song/detail": object["songs"] = [["id": 1, "name": "One"], ["id": 2, "name": "Two"]]
        default: object = ["code": 404]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
