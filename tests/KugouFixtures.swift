import Foundation

// This executable intentionally excludes Services/SecureVault.swift and never accesses Keychain.
enum SecureVault {
    static func read(key: String) throws -> Data? { fatalError("Production vault must not be called in synthetic checks") }
    static func save(_ data: Data, key: String) throws { fatalError("Production vault must not be called in synthetic checks") }
    static func remove(key: String) throws { fatalError("Production vault must not be called in synthetic checks") }
}
final class KugouMemoryVault: KugouCredentialVault {
    var data: Data?
    var failSave = false
    var failRemove = false
    var saves = 0
    init(_ credential: KugouCredential? = nil) throws { data = try credential.map { try JSONEncoder().encode($0) } }
    func read() throws -> Data? { data }
    func save(_ data: Data) throws { if failSave { throw KugouError.storage }; self.data = data; saves += 1 }
    func remove() throws { if failRemove { throw KugouError.storage }; data = nil }
}
final class KugouFixtureTransport: KugouTransport {
    var requests: [URLRequest] = []
    var response: [String: Any] = ["status": 1, "error_code": 0, "data": ["qrcode": "synthetic-key"]]
    var raw: Data?
    func send(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        return try raw ?? JSONSerialization.data(withJSONObject: response)
    }
}
@MainActor final class KugouFixtureAPI: KugouServing {
    var qrCalls = 0
    var checkCalls = 0
    var listCalls = 0
    var failLists = false
    var foreignScope = false
    var authorizeAt = 1
    var wrongDevice = false
    var holdKey = false
    var heldKey: CheckedContinuation<Void, Never>?
    var holdLists = false
    var heldLists: CheckedContinuation<Void, Never>?
    var holdTracks = false
    var trackCalls = 0
    var failTracks = false
    var heldTracks: CheckedContinuation<Void, Never>?
    let device = KugouDevice(mid: "123456789012345678", dev: String(repeating: "A", count: 32))
    func qrKey(device: KugouDevice) async throws -> String {
        qrCalls += 1
        if holdKey { await withCheckedContinuation { heldKey = $0 } }
        return "synthetic-key"
    }
    func checkQR(_ key: String, device: KugouDevice) async throws -> KugouQRResult {
        checkCalls += 1
        guard checkCalls >= authorizeAt else { return .waiting }
        return .authorized(try KugouCredential(userID: "42", token: "synthetic-token", device: wrongDevice ? self.device : device))
    }
    func playlists(_ c: KugouCredential, page: Int, size: Int) async throws -> KugouPage<KugouPlaylist> {
        listCalls += 1
        if holdLists { await withCheckedContinuation { heldLists = $0 } }
        if failLists { throw KugouError.rejected }
        let items = (page == 1 ? Array(1...100) : [101, 102]).map { n in
            KugouPlaylist(id: String(n), accountScope: foreignScope ? "kugou:99" : "kugou:\(c.userID)", name: "Synthetic list \(n)", ownerID: c.userID,
                trackCount: 2, artworkURL: nil, kind: .created, globalCollectionID: nil)
        }
        return KugouPage(items: items, total: 102, rawCount: items.count, fingerprint: "page-\(page)")
    }
    func tracks(_ c: KugouCredential, listID: String, page: Int, size: Int) async throws -> KugouPage<Song> {
        trackCalls += 1
        if holdTracks { await withCheckedContinuation { heldTracks = $0 } }
        if failTracks { throw KugouError.rejected }
        let song = Song(platform: .kugou, platformID: "77", title: "Synthetic", artist: "Fixture", album: "", duration: 1,
                        hash: String(repeating: "A", count: 32), accountScope: "kugou:\(c.userID)")
        return KugouPage(items: [song, song], total: 2, rawCount: 2, fingerprint: "duplicate-positions")
    }
}
