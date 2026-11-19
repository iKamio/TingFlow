// Isolated fake vault and fake HTTPS responses. No Keychain, server or user account is contacted.
import Foundation

@MainActor enum SecureVault {
    private static var memory: [String: Data] = [:]
    static func save(_ data: Data, key: String) throws { memory[key] = data }
    static func read(key: String) throws -> Data? { memory[key] }
    static func remove(key: String) throws { memory.removeValue(forKey: key) }
    static func reset() { memory = [:] }
}

final class EmbyPagingFixture: URLProtocol, @unchecked Sendable {
    struct Request {
        let type: String
        let offset: Int
        let limit: Int
        let path: String
        let hasCredential: Bool
        let body: [String: Any]?
    }
    private static let lock = NSLock()
    private static var recorded: [Request] = []
    private static var albumError = true
    private static var repeatAudioPage = false
    private static var rejectAudio = false
    private static var playback: [String: Any] = [:]
    private static var detail: [String: Any] = [:]
    static func setPlayback(_ value: [String: Any], detail: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }; playback = value; self.detail = detail
    }
    private func requestBody() -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable && data.count < 65536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func configure(albumError: Bool = true, repeatAudioPage: Bool = false, rejectAudio: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.albumError = albumError; self.repeatAudioPage = repeatAudioPage; self.rejectAudio = rejectAudio
    }
    static func requests() -> [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "example.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func parameter(_ key: String) -> String? { query.first { $0.name == key }?.value }
        let type = parameter("IncludeItemTypes") ?? ""
        let index = Int(parameter("StartIndex") ?? "0") ?? -1
        let limit = Int(parameter("Limit") ?? "0") ?? -1
        Self.lock.lock()
        Self.recorded.append(Request(type: type, offset: index, limit: limit, path: url.path,
                                     hasCredential: request.value(forHTTPHeaderField: "X-Emby-Token") != nil, body: requestBody()))
        let playback = Self.playback, detail = Self.detail
        let albumError = Self.albumError, repeatPage = Self.repeatAudioPage, unauthorized = Self.rejectAudio
        Self.lock.unlock()
        var status = 200
        var body: [String: Any] = [:]
        if url.path.hasSuffix("/Users/AuthenticateByName") {
            body = ["User": ["Id": "fixture-user", "Name": "Fixture"], "AccessToken": "fixture-session-only", "ServerId": "fixture-server"]
        } else if url.path.hasSuffix("/Users/fixture-user") { body = ["Id": "fixture-user", "Name": "Fixture"] }
        else if url.path.hasSuffix("/System/Info/Public") { body = ["Id": "fixture-server"] }
        else if url.path.hasSuffix("/Sessions/Logout") { body = [:] }
        else if url.path.hasSuffix("/PlaybackInfo") { body = playback }
        else if url.path.contains("/Users/fixture-user/Items/"), !url.path.hasSuffix("/Items") { body = detail }
        else if url.path.contains("/Playlists/fixture-list/Items") {
            let rows: [[String: Any]] = (index..<min(index + limit, 250)).map {
                ["Id": "same-song", "Type": "Audio", "Name": "Repeat", "PlaylistItemId": "entry-\($0)"]
            }
            body = ["Items": rows, "TotalRecordCount": 250]
        } else if url.path.hasSuffix("/Items"), type == "Audio" {
            if unauthorized { status = 401 }
            let start = repeatPage && index > 0 ? 0 : index
            let rows: [[String: Any]] = (start..<start + limit).map {
                ["Id": "song-\($0)", "Type": "Audio", "Name": "Song \($0)", "RunTimeTicks": 10_000_000]
            }
            body = ["Items": rows, "TotalRecordCount": 25_001]
        } else if url.path.hasSuffix("/Items"), type == "MusicAlbum" {
            if albumError { status = 503 }
            body = ["Items": [["Id": "fixture-album", "Type": "MusicAlbum", "Name": "Album"]], "TotalRecordCount": 1]
        } else if url.path.hasSuffix("/Items"), type == "Playlist" {
            body = ["Items": [["Id": "fixture-list", "Type": "Playlist", "MediaType": "Audio", "Name": "List"]], "TotalRecordCount": 1]
        } else { status = 404 }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
