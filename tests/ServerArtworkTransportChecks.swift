// Standalone macOS @main. Synthetic vault; ALL requests intercepted, never real accounts.
import Foundation
import ImageIO

@MainActor enum SecureVault {
    static var values: [String: Data] = [:]
    static func save(_ data: Data, key: String) throws { values[key] = data }
    static func read(key: String) throws -> Data? { values[key] }
    static func remove(key: String) throws { values.removeValue(forKey: key) }
}

private final class ArtworkFixture: URLProtocol, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    static func dimensionPNG(_ width: UInt32, _ height: UInt32) -> Data {
        var data = png
        func write(_ value: UInt32, at index: Int) {
            for offset in 0..<4 { data[index + offset] = UInt8(truncatingIfNeeded: value >> (24 - offset * 8)) }
        }
        write(width, at: 16); write(height, at: 20)
        var crc = UInt32.max
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320) }
        }
        write(~crc, at: 29)
        return data
    }
    struct Reply {
        var status = 200
        var mime = "image/png"
        var data = ArtworkFixture.png
        var length: Int? = nil
        var target: URL? = nil
        var hold = false
    }
    private static let lock = NSLock()
    private static var reply = Reply()
    private static var calls: [URLRequest] = []
    private static var stopped = 0
    static func set(_ value: Reply = Reply()) { lock.lock(); defer { lock.unlock() }; reply = value }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return calls }
    static func stops() -> Int { lock.lock(); defer { lock.unlock() }; return stopped }
    static func isArtwork(_ r: URLRequest) -> Bool {
        r.url?.path.hasSuffix("/Images/Primary") == true || r.url?.path.hasSuffix("/getCoverArt.view") == true
    }
    static func artworkCount() -> Int { requests().filter(isArtwork).count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    static func form(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(string: "https://fixture.invalid/?" + String(decoding: body(request), as: UTF8.self))?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "artwork.example.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.lock.lock(); Self.calls.append(request); let image = Self.reply; Self.lock.unlock()
        if Self.isArtwork(request) {
            // A held request is paused BEFORE any response callback. Some native
            // URLProtocol async-byte bridges buffer partial responses until EOF.
            // This seam verifies task/logout cancellation without relying on that
            // platform-specific buffering, while completed 404s are checked below.
            if image.hold { return }
            var headers = ["Content-Type": image.mime, "Location": "https://artwork.example.invalid/redirected", "Set-Cookie": "fixture=synthetic; Secure"]
            if let length = image.length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: image.target ?? url, statusCode: image.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: image.data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let type = query.first { $0.name == "IncludeItemTypes" }?.value
        var object: [String: Any] = [:]
        if url.path.hasSuffix("/Users/AuthenticateByName") {
            let login = (try? JSONSerialization.jsonObject(with: Self.body(request))) as? [String: Any]
            let name = login?["Username"] as? String ?? "fixture"
            object = ["User": ["Id": "user-" + name, "Name": name], "AccessToken": "synthetic-emby-token", "ServerId": "fixture-server"]
        } else if url.path.contains("/Users/user-"), !url.path.hasSuffix("/Items") {
            object = ["Id": url.lastPathComponent]
        } else if url.path.hasSuffix("/System/Info/Public") { object = ["Id": "fixture-server"] }
        else if url.path.hasSuffix("/Sessions/Logout") { object = [:] }
        else if url.path.hasSuffix("/Items") {
            var rows: [[String: Any]] = []
            if type == "MusicAlbum" {
                rows = [["Id": "album", "Name": "Album", "Type": "MusicAlbum", "AlbumArtist": "Actual artist", "ChildCount": 12, "ImageTags": ["Primary": "revision-1", "Other": 7]],
                        ["Id": "bad-metadata", "Type": "MusicAlbum", "ChildCount": "bad", "AlbumArtist": [], "AlbumArtists": false, "ImageTags": ["Primary": 42]]]
            } else if type == "Playlist" {
                rows = [["Id": "playlist", "Name": "List", "Type": "Playlist", "MediaType": "Audio", "ChildCount": 3, "ImageTags": ["Primary": "revision-2"]]]
            }
            object = ["Items": rows, "TotalRecordCount": rows.count]
        } else {
            var response: [String: Any] = ["status": "ok"]
            switch url.lastPathComponent {
            case "ping.view": break
            case "getAlbumList2.view": response["albumList2"] = ["album": [["id": "album", "name": "Album", "artist": "Actual artist", "songCount": 12, "coverArt": "opaque/id?&1"], ["id": "bad-metadata", "songCount": "bad", "coverArt": 42]]]
            case "getPlaylists.view": response["playlists"] = ["playlist": [["id": "playlist", "name": "List", "songCount": 3, "coverArt": "pl-cover"]]]
            default: response = ["status": "failed", "error": ["code": 70]]
            }
            object = ["subsonic-response": response]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        guard Self.isArtwork(request) else { return }
        Self.lock.lock(); Self.stopped += 1; Self.lock.unlock()
    }
}

@main @MainActor struct ServerArtworkTransportChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, "FAIL: " + label); count += 1 }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                precondition(Date() < deadline, "FAIL: bounded artwork lifecycle callback timed out")
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func rejected(_ load: () async throws -> Data?, _ label: String) async {
            do { _ = try await load(); preconditionFailure("FAIL: " + label) }
            catch { check(error is EmbyFailure || error is SubsonicFailure || error is CancellationError, label + " safe error") }
        }
        let base = try EmbyAddress.base("https://artwork.example.invalid/proxy")
        func config() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [ArtworkFixture.self]; return value
        }
        let emby = EmbyClient(base: base, device: "fixture-device", configuration: config())
        let sub = SubsonicClient(base: base, configuration: config())
        defer { emby.cancel(); sub.cancel() }
        let credential = SubsonicCredential(server: base, username: "synthetic-user", token: String(repeating: "a", count: 32), salt: String(repeating: "b", count: 32), navidrome: true)
        func embyImage() async throws -> Data? { try await emby.artwork(item: "collection", tag: "revision-1", token: "synthetic-emby-token", user: "user-a", pixels: 9999) }
        func subImage() async throws -> Data? { try await sub.artwork(id: "opaque/id?&1", credential: credential, pixels: 1) }
        check(try await embyImage() == ArtworkFixture.png, "Emby original bytes")
        let er = ArtworkFixture.requests().last!
        let eq = URLComponents(url: er.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(er.url!.path == "/proxy/Items/collection/Images/Primary" && er.httpMethod == "GET", "fixed Emby Primary route")
        check(Set(eq.map(\.name)) == ["MaxWidth", "MaxHeight", "Quality", "Tag"] && eq.first { $0.name == "MaxWidth" }?.value == "700", "Emby public-only bucket query")
        check(er.value(forHTTPHeaderField: "X-Emby-Token") == "synthetic-emby-token" && !er.url!.absoluteString.contains("synthetic"), "Emby token header only")
        check(!er.httpShouldHandleCookies && er.value(forHTTPHeaderField: "Cookie") == nil, "Emby cookies disabled")
        check(try await subImage() == ArtworkFixture.png, "Subsonic original bytes")
        let sr = ArtworkFixture.requests().last!, sf = ArtworkFixture.form(ArtworkFixture.requests().last!)
        check(sr.url!.path == "/proxy/rest/getCoverArt.view" && sr.url!.query == nil && sr.httpMethod == "POST", "fixed Subsonic body-only route")
        check(sf["u"] == credential.username && sf["t"] == credential.token && sf["s"] == credential.salt && sf["p"] == nil && sf["id"] == "opaque/id?&1" && sf["size"] == "320", "Subsonic encoded auth and opaque ID in form")
        check(!sr.httpShouldHandleCookies && sr.value(forHTTPHeaderField: "Cookie") == nil, "Subsonic cookies disabled")
        let failures: [ArtworkFixture.Reply] = [
            .init(mime: "application/json", data: Data("{}".utf8)),
            .init(mime: "text/html", data: Data("<html>private</html>".utf8)),
            .init(data: Data("{\"error\":\"private\"}".utf8)),
            .init(mime: "image/jpeg"), .init(data: Data()), .init(data: ArtworkFixture.png.prefix(24)),
            .init(length: 4_000_001), .init(data: Data(repeating: 0, count: 4_000_001)),
            .init(data: ArtworkFixture.dimensionPNG(16_385, 1)),
            .init(data: ArtworkFixture.dimensionPNG(10_000, 10_000)),
            .init(status: 302), .init(status: 307), .init(status: 401), .init(status: 403), .init(status: 500),
            .init(target: URL(string: "https://outside.invalid/image")),
            .init(target: URL(string: "https://artwork.example.invalid/other"))
        ]
        for (index, reply) in failures.enumerated() {
            ArtworkFixture.set(reply)
            let before = ArtworkFixture.artworkCount()
            await rejected(embyImage, "Emby rejects invalid binary/status/target #\(index)")
            await rejected(subImage, "Subsonic rejects invalid binary/status/target #\(index)")
            check(ArtworkFixture.artworkCount() == before + 2, "no follow-up, alternate target or retry")
        }
        FileHandle.standardError.write(Data("PASS: declared MIME, binary bounds and redirect rejection cases\n".utf8))
        ArtworkFixture.set(.init(status: 404))
        let before404 = ArtworkFixture.artworkCount()
        check(try await embyImage() == nil, "authenticated 404 only returns nil")
        check(try await subImage() == nil, "Subsonic 404 returns nil")
        check(ArtworkFixture.artworkCount() == before404 + 2, "missing images never retry or use alternate targets")
        ArtworkFixture.set()
        let beforeUnsafe = ArtworkFixture.artworkCount()
        await rejected({ try await emby.artwork(item: "../escape", token: "synthetic", user: "user-a") }, "Emby unsafe item")
        await rejected({ try await emby.artwork(item: "album", tag: "https://outside.invalid/", token: "synthetic", user: "user-a") }, "Emby unsafe revision")
        await rejected({ try await emby.artwork(item: "album", token: "bad\r\nvalue", user: "user-a") }, "Emby unsafe auth")
        await rejected({ try await sub.artwork(id: "bad\nvalue", credential: credential) }, "Subsonic control ID")
        await rejected({ try await sub.artwork(id: "https://outside.invalid/image", credential: credential) }, "Subsonic URL is not cover ID")
        let wrong = SubsonicCredential(server: URL(string: "https://outside.invalid")!, username: credential.username, token: credential.token, salt: credential.salt, navidrome: true)
        await rejected({ try await sub.artwork(id: "cover", credential: wrong) }, "Subsonic credential origin")
        check(ArtworkFixture.artworkCount() == beforeUnsafe, "invalid identities cause no transport")
        do { _ = try await sub.request("getCoverArt", credential: credential); preconditionFailure("binary method accepted as JSON") }
        catch { check(error as? SubsonicFailure == .response, "separate binary entry point") }
        let old = Data("{\"id\":\"old\",\"name\":\"Old\",\"accountScope\":\"scope\"}".utf8)
        check(try JSONDecoder().decode(EmbyAlbum.self, from: old).primaryImageTag == nil, "old Emby album snapshot")
        check(try JSONDecoder().decode(EmbyPlaylist.self, from: old).songCount == nil, "old Emby playlist snapshot")
        check(try JSONDecoder().decode(SubsonicAlbum.self, from: old).coverArtID == nil, "old Subsonic album snapshot")
        check(try JSONDecoder().decode(SubsonicPlaylist.self, from: old).songCount == nil, "old Subsonic playlist snapshot")

        SecureVault.values = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerArtwork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let e = EmbyStore(cacheDirectory: root.appendingPathComponent("emby")) { base, device in
            EmbyClient(base: base, device: device, configuration: config())
        }
        let s = SubsonicStore(cacheDirectory: root.appendingPathComponent("subsonic")) { base in
            SubsonicClient(base: base, configuration: config())
        }
        await e.signIn(baseURL: base.absoluteString, username: "a", password: "synthetic")
        check(e.isSignedIn && e.albums.count == 2 && e.playlists.count == 1, "actual Emby store activates and preserves malformed optional rows")
        let ea = e.albums[0], ep = e.playlists[0]
        check(ea.primaryImageTag == "revision-1" && ea.artist == "Actual artist" && ea.songCount == 12 && ep.songCount == 3, "Emby original metadata mapping")
        check(e.albums[1].primaryImageTag == nil && e.albums[1].songCount == nil && e.albums[1].artist == nil, "no fabricated Emby statistics")
        check(try JSONDecoder().decode(EmbyAlbum.self, from: JSONEncoder().encode(ea)) == ea, "new metadata snapshot roundtrip")
        var before = ArtworkFixture.artworkCount()
        check(try await e.artwork(for: ea, pixels: 100) == ArtworkFixture.png, "Emby store loads original")
        check(try await e.artwork(for: ea) == ArtworkFixture.png && ArtworkFixture.artworkCount() == before + 1, "Emby cache bucket reuse")
        check(try await e.artwork(for: ep) == ArtworkFixture.png, "Emby playlist original")
        var forged = ea; forged.primaryImageTag = "stale-revision"
        await rejected({ try await e.artwork(for: forged) }, "Emby current revision verified")
        await e.signIn(baseURL: base.absoluteString, username: "b", password: "synthetic")
        before = ArtworkFixture.artworkCount()
        await rejected({ try await e.artwork(for: ea) }, "old Emby account model")
        check(ArtworkFixture.artworkCount() == before, "Emby mismatch never returns cached data or requests")
        check(try await e.artwork(for: e.albums[0]) == ArtworkFixture.png && ArtworkFixture.artworkCount() == before + 1, "new account cannot reuse old image bytes")
        ArtworkFixture.set(.init(hold: true))
        before = ArtworkFixture.artworkCount()
        let pendingE = Task { @MainActor in
            do { _ = try await e.artwork(for: e.albums[0], pixels: 700); return false }
            catch { return error is CancellationError }
        }
        await waitUntil { ArtworkFixture.artworkCount() > before }
        check(ArtworkFixture.artworkCount() > before, "Emby pending image began")
        let stoppedE = ArtworkFixture.stops()
        await e.signOut()
        check(await pendingE.value && !e.isSignedIn, "Emby logout cancels old-account pending bytes")
        await waitUntil { ArtworkFixture.stops() > stoppedE }
        check(ArtworkFixture.stops() > stoppedE, "Emby logout reaches the held network task's stopLoading callback")
        await rejected({ try await e.artwork(for: ea) }, "Emby signed-out cached model")
        ArtworkFixture.set()
        await s.signIn(baseURL: base.absoluteString, username: "a", password: "synthetic", navidrome: true)
        check(s.isSignedIn && s.albums.count == 2 && s.playlists.count == 1, "actual Subsonic store optional metadata tolerance")
        let sa = s.albums[0], sp = s.playlists[0]
        check(sa.coverArtID == "opaque/id?&1" && sa.artist == "Actual artist" && sa.songCount == 12 && sp.songCount == 3, "Subsonic collection original mapping")
        check(s.albums[1].songCount == nil && s.albums[1].coverArtID == nil, "no fabricated Subsonic statistics")
        check(try JSONDecoder().decode(SubsonicAlbum.self, from: JSONEncoder().encode(sa)) == sa, "Subsonic metadata snapshot roundtrip")
        before = ArtworkFixture.artworkCount()
        check(try await s.artwork(for: sa, pixels: 100) == ArtworkFixture.png, "Subsonic store original")
        check(try await s.artwork(for: sa) == ArtworkFixture.png && ArtworkFixture.artworkCount() == before + 1, "Subsonic cache reuse")
        check(try await s.artwork(for: sp) == ArtworkFixture.png, "Subsonic playlist original")
        var stale = sa; stale.coverArtID = "stale-cover"
        await rejected({ try await s.artwork(for: stale) }, "Subsonic revision verified")
        check(try await s.artwork(for: s.albums[1]) == nil, "absent Subsonic cover ID is not invented")
        await s.signIn(baseURL: base.absoluteString, username: "b", password: "synthetic", navidrome: false)
        before = ArtworkFixture.artworkCount()
        await rejected({ try await s.artwork(for: sa) }, "old Subsonic account model")
        check(ArtworkFixture.artworkCount() == before, "Subsonic account mismatch no cached bytes or request")
        check(try await s.artwork(for: s.albums[0]) == ArtworkFixture.png && ArtworkFixture.artworkCount() == before + 1, "new Subsonic account reloads bytes")
        ArtworkFixture.set(.init(hold: true))
        before = ArtworkFixture.artworkCount()
        let pendingS = Task { @MainActor in
            do { _ = try await s.artwork(for: s.albums[0], pixels: 700); return false }
            catch { return error is CancellationError }
        }
        await waitUntil { ArtworkFixture.artworkCount() > before }
        check(ArtworkFixture.artworkCount() > before, "Subsonic pending image began")
        let stoppedS = ArtworkFixture.stops()
        await s.signOut()
        check(await pendingS.value && !s.isSignedIn && SecureVault.values.isEmpty, "Subsonic logout drops pending data and synthetic credentials")
        await waitUntil { ArtworkFixture.stops() > stoppedS }
        check(ArtworkFixture.stops() > stoppedS, "Subsonic logout reaches the held network task's stopLoading callback")
        await rejected({ try await s.artwork(for: sa) }, "Subsonic signed-out cached model")
        print("PASS: \(count) authenticated server ORIGINAL artwork checks; synthetic data only")
    }
}
