import Foundation

@MainActor enum SecureVault {
    static var values: [String: Data] = [:]
    static func save(_ data: Data, key: String) throws { values[key] = data }
    static func read(key: String) throws -> Data? { values[key] }
    static func remove(key: String) throws { values.removeValue(forKey: key) }
}
final class SubsonicFlowFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var validBodies = true
    static var requestsAreSafe: Bool { lock.lock(); defer { lock.unlock() }; return validBodies }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let body = String(decoding: Self.body(request), as: UTF8.self)
        let fields = URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems ?? []
        func value(_ name: String) -> String? { fields.first(where: { $0.name == name })?.value }
        let correct = url.scheme == "https" && url.host == "music.example.invalid" && url.query == nil &&
            url.path.hasPrefix("/music/rest/") && request.httpMethod == "POST" && value("p") == nil &&
            value("u") == "fixture" && value("t")?.count == 32 && value("s")?.count == 32
        Self.lock.lock(); Self.validBodies = Self.validBodies && correct; Self.lock.unlock()
        func song(_ id: String) -> [String: Any] { ["id": id, "title": "Fixture track", "artist": "Artist", "album": "Album", "duration": 123] }
        var object: [String: Any] = ["status": "ok", "version": "1.16.1"]
        switch url.lastPathComponent {
        case "ping.view": break
        case "getAlbumList2.view":
            let offset = Int(value("offset") ?? "0") ?? 0
            let end = offset == 0 ? 100 : 102
            let records: [[String: Any]] = (min(offset, end)..<end).map { ["id": "a\($0)", "name": "Album \($0)", "artist": "Artist"] }
            object["albumList2"] = ["album": records]
        case "getPlaylists.view": object["playlists"] = ["playlist": [["id": "pl/1", "name": "Private list"]]]
        case "getPlaylist.view": object["playlist"] = ["id": value("id") ?? "", "entry": [song("b"), song("a"), song("b")]]
        case "getAlbum.view": object["album"] = ["id": value("id") ?? "", "song": [song("a"), song("b")]]
        case "search3.view": object["searchResult3"] = ["song": [song("opaque/id?1")]]
        default: object = ["status": "failed", "error": ["code": 70]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["subsonic-response": object])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            if result.count > 65536 { break }
        }
        return result
    }
    override func stopLoading() { }
}
