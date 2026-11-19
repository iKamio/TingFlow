import Foundation

/// Standalone synthetic Store test. All network and credential storage are intercepted.
final class NeteasePlaylistTransportFixture: URLProtocol, @unchecked Sendable {
    enum Scenario { case fullInline, partialInline, malformed, verification }
    private static let lock = NSLock()
    private static var scenario = Scenario.fullInline
    private static var paths: [String] = []
    static func configure(_ value: Scenario) { lock.lock(); scenario = value; paths = []; lock.unlock() }
    static func requested() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func record(_ id: Int) -> [String: Any] {
        ["id": id, "name": "Song \(id)", "ar": [["name": "Synthetic artist"]], "dt": 120000]
    }
    override func startLoading() {
        guard let url = request.url, NeteaseWire.isAPIURL(url) else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        Self.lock.lock(); Self.paths.append(url.path); let mode = Self.scenario; Self.lock.unlock()
        var result: [String: Any] = ["code": 200]
        switch url.path {
        case "/eapi/nuser/account/get": result["account"] = ["id": 7]; result["profile"] = ["userId": 7, "nickname": "Fixture"]
        case "/eapi/user/playlist": result["more"] = false; result["playlist"] = []
        case "/eapi/v3/discovery/recommend/songs": result["data"] = ["dailySongs": []]
        case "/eapi/v1/discovery/recommend/resource": result["recommend"] = []
        case "/eapi/personalized/playlist": result["result"] = []
        case "/eapi/v6/playlist/detail":
            if mode == .verification { result = ["code": -460] }
            else {
                let ids = Array(1...256) + [1]
                let end = mode == .partialInline ? 64 : 256
                result["playlist"] = ["id": 101, "trackCount": mode == .malformed ? 258 : 257,
                    "trackIds": ids.map { ["id": $0] }, "tracks": Array(1...end).map(Self.record)]
            }
        case "/eapi/v3/song/detail": result["songs"] = Array(65...256).reversed().map(Self.record)
        default: result = ["code": 404]
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main @MainActor struct NeteasePlaylistTransportChecks {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1 }
        let make: @MainActor () -> NeteaseClient = {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NeteasePlaylistTransportFixture.self]
            return NeteaseClient(configuration: config, deviceID: String(repeating: "D", count: 52))
        }
        let scenarios: [NeteasePlaylistTransportFixture.Scenario] = [.fullInline, .partialInline, .malformed, .verification]
        for mode in scenarios {
            SecureVault.values["netease.native.weapi.session.v1"] = try JSONSerialization.data(withJSONObject: ["version": 1, "userID": "7", "cookies": [["name": "MUSIC_U", "value": "synthetic-playlist-session"]]])
            let store = NeteaseStore(clientFactory: make)
            NeteasePlaylistTransportFixture.configure(mode); await store.refresh()
            check(store.isSignedIn, "verified synthetic session")
            let list = NeteasePlaylist(id: "101", name: "257-track list", trackCount: 257, coverURL: nil, ownerName: "", accountScope: "netease:7")
            do {
                let songs = try await store.tracks(in: list)
                check(mode == .fullInline || mode == .partialInline, "malformed/risk must fail closed")
                check(songs.count == 257 && songs.first?.platformID == "1" && songs.last?.platformID == "1", "preserve full count and duplicate order")
                check(songs[64].title == "Song 65" && songs.allSatisfy { $0.accountScope == "netease:7" }, "missing details mapped by ID, never response order")
                let requests = NeteasePlaylistTransportFixture.requested()
                check(requests.filter { $0.hasSuffix("/playlist/detail") }.count == 1, "detail read only once")
                check(requests.filter { $0.hasSuffix("/song/detail") }.count == (mode == .fullInline ? 0 : 1), "fully supplied 257-track list avoids redundant request")
                let before = requests.count
                _ = try await store.tracks(in: list)
                check(NeteasePlaylistTransportFixture.requested().count == before, "safe memory cache reused")
            } catch {
                if mode == .malformed { check(error as? NeteaseError == .incomplete, "inconsistent count not accepted") }
                else if mode == .verification { check(error as? NeteaseError == .verification, "risk is not parsed as empty playlist") }
                else { throw error }
            }
            await store.signOut()
        }
        print("PASS: \(count) actual-Store 257-track inline/missing detail, count, order, cache and risk checks")
    }
}
