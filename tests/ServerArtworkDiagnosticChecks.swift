// Standalone macOS, Swift 5. Link ONLY the core + Subsonic inputs listed below.
// No production vault, other test fixtures, real accounts, environment or network.
// xcrun swiftc -swift-version 5 -parse-as-library \
//   app/TingFlow/Core/Models.swift app/TingFlow/Core/PlaybackResource.swift \
//   app/TingFlow/Playback/ListeningSession.swift app/TingFlow/Core/ServerArtworkCache.swift \
//   app/TingFlow/Core/ServerArtworkDiagnostic.swift \
//   app/TingFlow/Subsonic/SubsonicClient.swift app/TingFlow/Subsonic/SubsonicStore.swift \
//   tests/ServerArtworkDiagnosticChecks.swift -o /tmp/server-artwork-diagnostic-checks
import Foundation

@MainActor enum SecureVault {
    static var values: [String: Data] = [:]
    static func save(_ data: Data, key: String) throws { values[key] = data }
    static func read(key: String) throws -> Data? { values[key] }
    static func remove(key: String) throws { values.removeValue(forKey: key) }
}

private final class DiagnosticProtocol: URLProtocol, @unchecked Sendable {
    static let base = "https://artwork.example.invalid/proxy"
    static let cover = "opaque/id?&diag-secret-cover"
    static let remote = "diag-secret-remote-message"
    static let title = "diag-secret-library-title"
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
        write(~crc, at: 29); return data
    }
    struct Reply {
        var status = 200
        var mime: String? = "image/png"
        var data = DiagnosticProtocol.png
        var length: Int? = nil
        var hold = false
    }
    struct Call { let request: URLRequest; let fields: [String: String] }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var calls: [Call] = []
    private static var held: [String: [DiagnosticProtocol]] = [:]
    private static var stopped: [String: Int] = [:]
    private static var rejected = 0
    private let stateLock = NSLock()
    private var ended = false
    private var wasHeld = false
    private var coverID = ""

    static func json(code: Any = 50, status: Any = "failed", message: String = remote) -> Data {
        try! JSONSerialization.data(withJSONObject: ["subsonic-response": ["status": status, "error": ["code": code, "message": message]]])
    }
    static func set(_ id: String, _ reply: Reply = Reply()) {
        lock.lock(); defer { lock.unlock() }; replies[id] = reply
    }
    static func requests() -> [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    static func count(_ id: String? = nil) -> Int {
        requests().filter { $0.request.url?.path == "/proxy/rest/getCoverArt.view" && (id == nil || $0.fields["id"] == id) }.count
    }
    static func holding(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return held[id]?.count ?? 0 }
    static func stops(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return stopped[id, default: 0] }
    static func violations() -> Int { lock.lock(); defer { lock.unlock() }; return rejected }
    static func release(_ id: String, _ reply: Reply = Reply()) {
        lock.lock(); let pending = held.removeValue(forKey: id) ?? []; lock.unlock()
        for item in pending { item.send(reply) }
    }
    // Claim ALL requests so an incorrect production endpoint cannot escape the fixture.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
    override func startLoading() {
        let routes = ["ping.view", "getAlbumList2.view", "getPlaylists.view", "getCoverArt.view"]
        guard let url = request.url, url.scheme == "https", url.host == "artwork.example.invalid",
              url.user == nil, url.password == nil, url.port == nil,
              routes.contains(url.lastPathComponent), url.path == "/proxy/rest/" + url.lastPathComponent else {
            Self.lock.lock(); Self.rejected += 1; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let form = String(decoding: Self.body(request), as: UTF8.self)
        let items = URLComponents(string: "https://example.invalid/?" + form)?.queryItems ?? []
        let fields = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        Self.lock.lock(); Self.calls.append(Call(request: request, fields: fields))
        let reply = Self.replies[fields["id"] ?? ""] ?? Reply(); Self.lock.unlock()
        if url.lastPathComponent == "getCoverArt.view" {
            stateLock.lock(); coverID = fields["id"] ?? ""; wasHeld = reply.hold; stateLock.unlock()
            // Pause BEFORE headers/body; do not depend on native partial-byte buffering.
            if reply.hold {
                Self.lock.lock(); Self.held[coverID, default: []].append(self); Self.lock.unlock()
            } else { send(reply) }
            return
        }
        var response: [String: Any] = ["status": "ok"]
        if url.lastPathComponent == "getAlbumList2.view" {
            response["albumList2"] = ["album": [
                ["id": "permission-album", "name": Self.title, "coverArt": "cover-permission"],
                ["id": "missing-album", "name": Self.title, "coverArt": "cover-missing"],
                ["id": "png-album", "name": Self.title, "coverArt": Self.cover],
                ["id": "no-cover-album", "name": Self.title],
                ["id": "auth-album", "name": Self.title, "coverArt": "cover-auth"]]]
        } else if url.lastPathComponent == "getPlaylists.view" {
            response["playlists"] = ["playlist": [
                ["id": "permission-list", "name": Self.title, "coverArt": "list-permission"],
                ["id": "png-list", "name": Self.title, "coverArt": "list-png"],
                ["id": "no-cover-list", "name": Self.title]]]
        }
        send(Reply(mime: "application/json", data: try! JSONSerialization.data(withJSONObject: ["subsonic-response": response])))
    }
    private func send(_ reply: Reply) {
        stateLock.lock(); guard !ended else { stateLock.unlock(); return }; ended = true; stateLock.unlock()
        guard let url = request.url else { return }
        var headers = ["Set-Cookie": "diag-secret-cookie=synthetic; Secure"]
        if let mime = reply.mime { headers["Content-Type"] = mime }
        if let length = reply.length { headers["Content-Length"] = String(length) }
        if (300..<400).contains(reply.status) { headers["Location"] = Self.base + "/diag-secret-redirect" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        stateLock.lock(); ended = true; let held = wasHeld, id = coverID; wasHeld = false; stateLock.unlock()
        if held { Self.lock.lock(); Self.stopped[id, default: 0] += 1; Self.lock.unlock() }
    }
}

@main @MainActor struct ServerArtworkDiagnosticChecks {
    private typealias D = ServerArtworkDiagnostic
    private typealias F = DiagnosticProtocol
    private static var checks = 0
    private enum Outcome { case value(ServerArtworkResult), failure(ServerArtworkDiagnosticFailure), cancelled, unexpected }
    @MainActor private final class Pending {
        var result: Outcome?
        var task: Task<Void, Never>?
    }
    @MainActor private final class Gate {
        var callbacks: [CheckedContinuation<Data?, Never>?] = []
        var returned = 0
        var cancelledOnReturn = false
        func read() async -> Data? {
            defer { returned += 1; cancelledOnReturn = Task.isCancelled }
            return await withCheckedContinuation { callbacks.append($0) }
        }
        func release(_ index: Int, _ data: Data?) {
            guard callbacks.indices.contains(index), let callback = callbacks[index] else { preconditionFailure("FAIL: missing controlled callback") }
            callbacks[index] = nil; callback.resume(returning: data)
        }
    }
    private static func check(_ value: Bool, _ label: String) {
        precondition(value, "FAIL: " + label); checks += 1
    }
    private static func until(_ ready: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !ready() {
            precondition(Date() < deadline, "FAIL: bounded diagnostic checkpoint timed out")
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func start(_ load: @escaping @MainActor () async throws -> ServerArtworkResult) -> Pending {
        let pending = Pending()
        pending.task = Task { @MainActor in
            do { pending.result = .value(try await load()) }
            catch is CancellationError { pending.result = .cancelled }
            catch let error as ServerArtworkDiagnosticFailure { pending.result = .failure(error) }
            catch { pending.result = .unexpected }
        }
        return pending
    }
    private static func finish(_ pending: Pending) async -> Outcome {
        await until { pending.result != nil }
        await pending.task?.value
        return pending.result!
    }
    private static func failure(_ load: @MainActor () async throws -> ServerArtworkResult) async -> D {
        do { _ = try await load(); preconditionFailure("FAIL: failed artwork pretended success") }
        catch let error as ServerArtworkDiagnosticFailure {
            check(error.localizedDescription == "封面未载入，请查看脱敏封面诊断。", "fixed localized error")
            safe(error.diagnostic); return error.diagnostic
        } catch { preconditionFailure("FAIL: diagnostic error lost or unsanitized") }
    }
    private static func safe(_ diagnostic: D) {
        let forbidden = [F.base, "artwork.example.invalid", F.cover, F.remote, F.title,
                         "diag-secret", "synthetic-user-private", String(repeating: "a", count: 32),
                         String(repeating: "b", count: 32)]
        check(forbidden.allSatisfy { !diagnostic.text.contains($0) }, "diagnostic never echoes synthetic private input")
        check(diagnostic.text.utf8.count < 4096, "shareable diagnostic has bounded fixed text")
    }
    private nonisolated static func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [F.self]; return config
    }
    static func main() async throws {
        model()
        try await client()
        try await cache()
        try await stores()
        check(F.violations() == 0, "all synthetic requests stayed on exact allowlisted fixture routes")
        print("PASS: \(checks) offline server artwork diagnostic checks; synthetic data only")
    }

    private static func model() {
        for (raw, expected) in [(" Image/PNG ; charset=x", D.MIME.png), ("image/jpeg", .jpeg),
            ("image/webp", .webp), ("image/gif", .gif), ("image/heic", .heic), ("image/heif", .heif),
            ("APPLICATION/JSON; charset=utf-8", .json), ("text/xml", .xml), ("application/xml", .xml),
            ("text/html", .html), ("application/xhtml+xml", .html), ("application/octet-stream", .binary),
            ("image/jpg", .other), ("image/svg+xml", .other), ("image/diag-secret-mime", .other), ("", .missing)] {
            check(D.MIME.classify(raw) == expected, "raw MIME collapses to allowlist classification")
        }
        check(D.MIME.classify(nil) == .missing && !D.MIME.other.isImage && !D.MIME.binary.isImage, "unobserved and nonimage MIME are not images")
        check(D.ImageFormat.classify("diag-secret-uti") == .other && D.ImageFormat.classify(nil) == .unobserved, "UTI cannot enter raw diagnostic text")
        for code in [40, 41, 42, 43, 44, 50, 70, 10, 0] {
            let parsed = D.apiEnvelope(F.json(code: code))
            let expected: D.Issue = (40...44).contains(code) ? .authentication : code == 50 ? .permission : code == 70 ? .notFound : .api
            check(parsed?.status == .failed && parsed?.code == code && D.apiIssue(code) == expected, "API code maps without remote message")
        }
        for raw in ["true", "false", "40.5", "1e99", "1000001", "-1000001", "\"40\"", "null", "{}", "[]"] {
            let data = Data(("{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"code\":" + raw + "}}}").utf8)
            let parsed = D.apiEnvelope(data)
            check(parsed?.status == .failed && parsed?.code == nil, "bool fraction huge and nonnumeric codes are not invented integers")
        }
        for raw in ["", "{}", "[]", "null", "{broken", "{\"subsonic-response\":true}"] {
            check(D.apiEnvelope(Data(raw.utf8)) == nil, "malformed envelope rejected")
        }
        check(D.apiEnvelope(F.json(status: true))?.status == .invalid, "boolean API status is invalid")
        check(D.apiEnvelope(F.json(status: "ok"))?.status == .ok, "only explicit ok status recognized")
        var bounded = F.json(message: String(repeating: F.remote, count: 1000))
        bounded.append(Data(repeating: 32, count: 65_536 - bounded.count))
        check(D.apiEnvelope(bounded)?.code == 50, "inclusive 64 KiB JSON bound")
        bounded.append(32)
        check(D.apiEnvelope(bounded) == nil, "oversized JSON is not parsed")
        var d = D(service: .navidrome, pixels: Int.max)
        d.stage = .api; d.issue = .permission; d.apiStatus = .failed; d.apiCode = 50; d.httpStatus = 200
        d.mime = D.MIME.classify("image/diag-secret-mime"); safe(d)
        check(d.pixels == 700 && D(service: .subsonic, pixels: Int.min).pixels == 320, "diagnostic clamps pixel buckets")
        let error = ServerArtworkDiagnosticFailure(diagnostic: d)
        check(error == ServerArtworkDiagnosticFailure(diagnostic: d), "safe failure preserves value equality")
        d.httpStatus = Int.max; d.apiCode = Int.max; d.bytesReceived = Int.max; d.expectedBytes = Int64.max
        check(!d.text.contains(String(Int.max)), "out-of-range values are not printed raw")
        safe(d)
    }

    private static func client() async throws {
        let base = try SubsonicPolicy.base(F.base)
        let client = SubsonicClient(base: base, configuration: config()); defer { client.cancel() }
        let credential = SubsonicCredential(server: base, username: "synthetic-user-private", token: String(repeating: "a", count: 32), salt: String(repeating: "b", count: 32), navidrome: true)
        func load(_ id: String = F.cover, _ pixels: Int = 320) async throws -> ServerArtworkResult {
            try await client.artworkResult(id: id, credential: credential, pixels: pixels)
        }
        F.set(F.cover, .init(length: F.png.count))
        let image = try await load(F.cover, 1), d = image.diagnostic
        check(image.data == F.png && d.origin == .network && d.stage == .completed && d.issue == .none, "complete PNG is the only successful original")
        check(d.service == .navidrome && d.httpStatus == 200 && d.apiCode == nil && d.apiStatus == .unobserved, "PNG diagnostic does not invent API observations")
        check(d.bytesReceived == F.png.count && d.expectedBytes == Int64(F.png.count) && d.imageFormat == .png && d.mime == .png && d.pixels == 320, "PNG reports observed bytes format and bucket")
        safe(d)
        let call = F.requests().last!, request = call.request, fields = call.fields
        check(request.httpMethod == "POST" && request.url?.path == "/proxy/rest/getCoverArt.view" && request.url?.query == nil && request.url?.fragment == nil, "fixed HTTPS getCoverArt POST route has no secret query")
        check(Set(fields.keys) == Set(["u", "t", "s", "v", "c", "f", "id", "size"]) && fields["u"] == credential.username && fields["t"] == credential.token && fields["s"] == credential.salt && fields["id"] == F.cover && fields["size"] == "320" && fields["p"] == nil, "auth and opaque cover ID remain encoded POST body only")
        check(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "no cookies or alternate authorization")
        let publicHeaders = (request.allHTTPHeaderFields ?? [:]).values.joined(separator: " ")
        check([credential.username, credential.token, credential.salt, F.cover].allSatisfy { !publicHeaders.contains($0) }, "request auth does not migrate into headers")
        check(try await load(F.cover, Int.max).diagnostic.pixels == 700, "large request uses fixed 700 bucket")
        let cases: [(String, F.Reply, D.Stage, D.Issue, Int?, Int?)] = [
            ("permission", .init(mime: "application/json", data: F.json()), .api, .permission, 200, 50),
            ("auth-http", .init(status: 401, mime: "application/json", data: F.json(code: 40)), .api, .authentication, 401, 40),
            ("malformed", .init(mime: "application/json", data: Data("{diag-secret-malformed".utf8)), .api, .invalidEnvelope, 200, nil),
            ("bad-image", .init(data: Data(F.remote.utf8)), .imageContainer, .invalidContainer, 200, nil),
            ("gzip-image", .init(data: Data([31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 75, 76, 2, 0])), .imageContainer, .invalidContainer, 200, nil),
            ("other-mime", .init(mime: "image/diag-secret-private", data: F.png), .headers, .unexpectedMIME, 200, nil),
            ("html", .init(mime: "text/html", data: Data(F.remote.utf8)), .headers, .unexpectedMIME, 200, nil),
            ("redirect", .init(status: 301), .headers, .redirect, 301, nil),
            ("image-length", .init(length: 4_000_001), .headers, .tooLarge, 200, nil),
            ("json-length", .init(mime: "application/json", data: F.json(), length: 65_537), .headers, .tooLarge, 200, nil),
            ("image-body", .init(data: Data(repeating: 0, count: 4_000_001)), .body, .tooLarge, 200, nil),
            ("json-body", .init(mime: "application/json", data: Data(repeating: 32, count: 65_537)), .body, .tooLarge, 200, nil)]
        for (id, reply, stage, issue, http, code) in cases {
            F.set(id, reply); let before = F.count()
            let result = await failure { try await load(id) }
            check(result.origin == .network && result.stage == stage && result.issue == issue && result.httpStatus == http && result.apiCode == code, "failure retains correct request-local stage HTTP and API code")
            check(F.count() == before + 1 && result.bytesReceived <= 4_000_001, "no retry redirect follow-up or unbounded read")
            if id == "other-mime" { check(result.mime == .other, "unknown raw MIME never retained") }
        }
        for code in [0, 10, 40, 41, 42, 43, 44] {
            F.set("api-code", .init(mime: "application/json", data: F.json(code: code)))
            let result = await failure { try await load("api-code") }
            check(result.apiCode == code && result.stage == .api && result.issue == D.apiIssue(code) && result.apiStatus == .failed, "HTTP200 API failure is never image success")
        }
        F.set("missing", .init(mime: "application/json", data: F.json(code: 70)))
        let missing = try await load("missing")
        check(missing.data == nil && missing.diagnostic.issue == .notFound && missing.diagnostic.stage == .api && missing.diagnostic.httpStatus == 200 && missing.diagnostic.apiCode == 70 && missing.diagnostic.apiStatus == .failed, "code70 is genuine missing rather than empty successful image")
        safe(missing.diagnostic)
        let huge = F.json(message: String(repeating: F.remote, count: 1000))
        F.set("long-message", .init(mime: "application/json", data: huge))
        let long = await failure { try await load("long-message") }
        check(long.apiCode == 50 && long.issue == .permission, "large remote message is ignored not echoed")
    }

    private static func cache() async throws {
        let cache = ServerArtworkCache()
        let key = ServerArtworkCache.Key(scope: "offline-account", id: "error", pixels: 320)
        var d = D(service: .navidrome, pixels: 320)
        d.stage = .api; d.issue = .permission; d.httpStatus = 200; d.apiCode = 50; d.apiStatus = .failed
        let allowed = ServerArtworkDiagnosticFailure(diagnostic: d)
        let privateError = NSError(domain: "diag-secret-domain", code: 91, userInfo: [
            NSLocalizedDescriptionKey: F.remote, NSURLErrorKey: URL(string: F.base)!,
            "tokenbody": Data("diag-secret-token-body".utf8)])
        var attempts = 0
        let unsafeErrors: [Error] = [privateError, NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: allowed])]
        for error in unsafeErrors {
            do { _ = try await cache.data(for: key) { attempts += 1; throw error }; preconditionFailure("FAIL: generic error accepted") }
            catch let error as ServerArtworkCache.Failure {
                check(error == .invalidData && !String(reflecting: error).contains("diag-secret"), "generic and wrapped errors retain no underlying data")
            } catch { preconditionFailure("FAIL: generic cache error escaped sanitization") }
        }
        for _ in 0..<2 {
            do { _ = try await cache.data(for: key) { attempts += 1; throw allowed }; preconditionFailure("FAIL: safe failure accepted as data") }
            catch let error as ServerArtworkDiagnosticFailure { check(error == allowed, "ONLY typed diagnostic passes cache exactly") }
            catch { preconditionFailure("FAIL: typed diagnostic was flattened to invalidData") }
        }
        check(attempts == 4 && cache.statistics.entries == 0 && cache.statistics.flights == 0, "all cache errors permit a real fresh attempt")
        let gate = Gate()
        func load() async throws -> ServerArtworkResult {
            let data = try await cache.data(for: key) { await gate.read() }
            return ServerArtworkResult(data: data, diagnostic: d)
        }
        let first = start { try await load() }, shared = start { try await load() }
        await until { gate.callbacks.count == 1 && cache.statistics.waiters == 2 }
        first.task?.cancel()
        if case .cancelled = await finish(first) { check(true, "cancelled waiter promptly receives CancellationError") }
        else { preconditionFailure("FAIL: waiter cancellation lost") }
        check(cache.statistics.waiters == 1 && cache.statistics.flights == 1, "one cancelled waiter does not cancel shared worker")
        gate.release(0, Data([1]))
        if case .value(let result) = await finish(shared) { check(result.data == Data([1]) && !gate.cancelledOnReturn, "remaining waiter still receives shared data") }
        else { preconditionFailure("FAIL: shared waiter cancelled") }
        cache.clear()
        let old = start { try await load() }, oldShared = start { try await load() }
        await until { gate.callbacks.count == 2 && cache.statistics.waiters == 2 }
        cache.clear()
        for item in [old, oldShared] {
            if case .cancelled = await finish(item) { check(true, "clear cancels all old-account waiters before loader returns") }
            else { preconditionFailure("FAIL: clear exposed old result") }
        }
        let replacement = start { try await load() }
        await until { gate.callbacks.count == 3 && cache.statistics.flights == 1 }
        gate.release(1, Data([9])) // deliberately uncooperative, late old epoch
        await until { gate.returned == 2 }
        check(cache.statistics.entries == 0 && cache.statistics.flights == 1, "late old epoch cannot cache data or remove replacement flight")
        gate.release(2, Data([2]))
        if case .value(let result) = await finish(replacement) { check(result.data == Data([2]), "replacement survives late old completion") }
        else { preconditionFailure("FAIL: replacement lost") }
        let cached = try await cache.data(for: key) { preconditionFailure("FAIL: replacement cache missed") }
        check(cached == Data([2]) && cache.statistics.waiters == 0 && cache.statistics.flights == 0, "cache stores only current generation data")
        cache.clear()
    }

    private static func stores() async throws {
        SecureVault.values = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkDiagnostic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); SecureVault.values = [:] }
        let store = SubsonicStore(cacheDirectory: root.appendingPathComponent("a")) { SubsonicClient(base: $0, configuration: config()) }
        await store.signIn(baseURL: F.base, username: "offline-a", password: "synthetic-only", navidrome: true)
        check(store.isSignedIn && store.albums.count == 5 && store.playlists.count == 3 && store.artworkService == .navidrome, "real store login ping and metadata fixtures activate")
        let permission = store.albums.first { $0.id == "permission-album" }!
        let missing = store.albums.first { $0.id == "missing-album" }!
        let png = store.albums.first { $0.id == "png-album" }!
        let noCover = store.albums.first { $0.id == "no-cover-album" }!
        let authentication = store.albums.first { $0.id == "auth-album" }!
        let list = store.playlists.first { $0.id == "permission-list" }!
        let pngList = store.playlists.first { $0.id == "png-list" }!
        let noCoverList = store.playlists.first { $0.id == "no-cover-list" }!
        F.set("cover-permission", .init(mime: "application/json", data: F.json()))
        F.set("list-permission", .init(mime: "application/json", data: F.json()))
        let beforeErrors = F.count()
        var saved: D?
        for _ in 0..<2 {
            let d = await failure { try await store.artworkResult(for: permission) }
            check(d.origin == .network && d.stage == .api && d.issue == .permission && d.httpStatus == 200 && d.apiCode == 50 && d.apiStatus == .failed, "HTTP200/code50 survives real store cache sanitization")
            if saved == nil { saved = d } else { check(saved == d, "fresh attempt retains same request observations") }
        }
        check(F.count() == beforeErrors + 2, "permission failures are neither cached nor converted to negative entries")
        let ld = await failure { try await store.artworkResult(for: list) }
        check(ld.apiCode == 50 && ld.issue == .permission && ld.service == .navidrome, "playlist diagnostic overload preserves API errors")
        F.set("cover-permission", .init(hold: true))
        let beforeShared = F.count("cover-permission")
        let sharedFirst = start { try await store.artworkResult(for: permission) }
        await until { F.holding("cover-permission") == 1 }
        var secondStarted = false
        let sharedSecond = start {
            secondStarted = true
            return try await store.artworkResult(for: permission)
        }
        await until { secondStarted }
        check(F.count("cover-permission") == beforeShared + 1, "same cover diagnostic callers share one actual request")
        F.release("cover-permission", .init(mime: "application/json", data: F.json(code: 50)))
        if case .failure(let firstFailure) = await finish(sharedFirst),
           case .failure(let secondFailure) = await finish(sharedSecond) {
            check(firstFailure == secondFailure && firstFailure.diagnostic.apiCode == 50 && firstFailure.diagnostic.httpStatus == 200,
                  "coalesced HTTP200/code50 diagnostic reaches both callers without flattened cache error")
            safe(firstFailure.diagnostic); safe(secondFailure.diagnostic)
        } else { preconditionFailure("FAIL: shared request diagnostic lost") }
        F.set("cover-permission", .init(mime: "application/json", data: F.json()))
        F.set("cover-missing", .init(mime: "application/json", data: F.json(code: 70)))
        let beforeMissing = F.count()
        let absent = try await store.artworkResult(for: missing)
        let negative = try await store.artworkResult(for: missing)
        check(absent.data == nil && absent.diagnostic.origin == .network && absent.diagnostic.issue == .notFound && absent.diagnostic.apiCode == 70 && absent.diagnostic.httpStatus == 200, "real missing code70 reaches store as nil with evidence")
        check(negative.data == nil && negative.diagnostic.origin == .cacheOrShared && negative.diagnostic.issue == .notFound && negative.diagnostic.httpStatus == nil && negative.diagnostic.apiCode == nil && negative.diagnostic.apiStatus == .unobserved && negative.diagnostic.bytesReceived == 0 && negative.diagnostic.imageFormat == .unobserved && F.count() == beforeMissing + 1, "negative cache does not invent a second HTTP200/code70 observation")
        F.set(F.cover, .init(length: F.png.count)); F.set("list-png", .init(length: F.png.count))
        let beforePNG = F.count()
        let original = try await store.artworkResult(for: png, pixels: 1)
        let cached = try await store.artworkResult(for: png, pixels: 320)
        check(original.data == F.png && original.diagnostic.origin == .network && original.diagnostic.stage == .completed && original.diagnostic.bytesReceived == F.png.count, "actual store returns original PNG with network diagnostic")
        check(cached.data == F.png && cached.diagnostic.origin == .cacheOrShared && cached.diagnostic.httpStatus == nil && cached.diagnostic.apiCode == nil && cached.diagnostic.apiStatus == .unobserved && cached.diagnostic.bytesReceived == F.png.count && F.count() == beforePNG + 1, "positive cache has fresh local diagnostic no fabricated network observations")
        check(cached.diagnostic.expectedBytes == nil && (cached.diagnostic.imageFormat == .png || cached.diagnostic.imageFormat == .unobserved), "cached byte format comes only from available data")
        let playlistImage = try await store.artworkResult(for: pngList)
        check(playlistImage.data == F.png && playlistImage.diagnostic.stage == .completed, "actual playlist original PNG")
        let beforeMetadata = F.count()
        for result in [try await store.artworkResult(for: noCover), try await store.artworkResult(for: noCoverList)] {
            check(result.data == nil && result.diagnostic.origin == .metadata && result.diagnostic.issue == .missingID && result.diagnostic.httpStatus == nil && result.diagnostic.apiCode == nil && result.diagnostic.bytesReceived == 0, "missing album and playlist IDs have metadata-only diagnostics")
            safe(result.diagnostic)
        }
        check(F.count() == beforeMetadata, "absent cover IDs cause no network activity")
        // Different IDs are held concurrently, then completed in the opposite order.
        F.set("cover-permission", .init(hold: true)); F.set("cover-auth", .init(hold: true))
        let pc = F.count("cover-permission"), ac = F.count("cover-auth")
        let p = start { try await store.artworkResult(for: permission, pixels: 700) }
        let a = start { try await store.artworkResult(for: authentication) }
        await until { F.count("cover-permission") == pc + 1 && F.count("cover-auth") == ac + 1 && F.holding("cover-permission") == 1 && F.holding("cover-auth") == 1 }
        F.release("cover-auth", .init(mime: "application/json", data: F.json(code: 40)))
        F.release("cover-permission", .init(mime: "application/json", data: F.json(code: 50)))
        if case .failure(let pe) = await finish(p), case .failure(let ae) = await finish(a) {
            check(pe.diagnostic.apiCode == 50 && pe.diagnostic.issue == .permission && pe.diagnostic.pixels == 700 && ae.diagnostic.apiCode == 40 && ae.diagnostic.issue == .authentication && ae.diagnostic.pixels == 320, "concurrent IDs retain their own errors without global diagnostic state")
            safe(pe.diagnostic); safe(ae.diagnostic)
        } else { preconditionFailure("FAIL: concurrent request diagnostics lost") }
        // A second real store cannot reuse the first store's bytes or service state.
        SecureVault.values = [:]
        let other = SubsonicStore(cacheDirectory: root.appendingPathComponent("b")) { SubsonicClient(base: $0, configuration: config()) }
        await other.signIn(baseURL: F.base, username: "offline-other", password: "synthetic-only", navidrome: false)
        check(other.isSignedIn && other.artworkService == .subsonic && store.artworkService == .navidrome, "service classification is per active store")
        let otherPNG = other.albums.first { $0.id == "png-album" }!
        let beforeOther = F.count(F.cover)
        let otherImage = try await other.artworkResult(for: otherPNG)
        check(otherImage.data == F.png && otherImage.diagnostic.origin == .network && otherImage.diagnostic.service == .subsonic && F.count(F.cover) == beforeOther + 1, "independent account/store starts its own artwork request")
        let retained = try await store.artworkResult(for: png)
        check(retained.diagnostic.origin == .cacheOrShared && retained.diagnostic.service == .navidrome && saved?.apiCode == 50 && saved?.httpStatus == 200 && saved?.issue == .permission, "another store or request cannot overwrite saved diagnostics")
        var forged = png; forged.coverArtID = "stale-cover"
        let beforeForged = F.count()
        let stale = await failure { try await store.artworkResult(for: forged) }
        check(stale.stage == .validation && stale.issue == .invalidContext && stale.httpStatus == nil && F.count() == beforeForged, "stale collection revision cannot use cache or request network")
        // Logout must cancel a held task before ANY response, not report a fake failure.
        F.set(F.cover, .init(hold: true))
        let beforeHeld = F.count(F.cover), beforeStops = F.stops(F.cover)
        let pending = start { try await store.artworkResult(for: png, pixels: 700) }
        await until { F.count(F.cover) == beforeHeld + 1 && F.holding(F.cover) == 1 }
        await store.signOut()
        if case .cancelled = await finish(pending) { check(!store.isSignedIn, "logout promptly cancels old account artwork task") }
        else { preconditionFailure("FAIL: account loss returned late artwork or diagnostic failure") }
        await until { F.stops(F.cover) > beforeStops }
        check(F.stops(F.cover) > beforeStops, "logout reaches URLProtocol stopLoading on held request")
        F.release(F.cover) // cancelled protocol refuses a late callback; cache late epochs tested above
        F.set(F.cover, .init(length: F.png.count))
        await store.signIn(baseURL: F.base, username: "offline-new", password: "synthetic-only", navidrome: false)
        check(store.isSignedIn && store.artworkService == .subsonic, "new account activates independently after cancellation")
        let newPNG = store.albums.first { $0.id == "png-album" }!
        let beforeNew = F.count(F.cover)
        let fresh = try await store.artworkResult(for: newPNG, pixels: 700)
        check(fresh.data == F.png && fresh.diagnostic.origin == .network && fresh.diagnostic.service == .subsonic && fresh.diagnostic.httpStatus == 200 && F.count(F.cover) == beforeNew + 1, "new account cannot inherit old flight cache or diagnostic")
        let old = await failure { try await store.artworkResult(for: png) }
        check(old.stage == .validation && old.issue == .invalidContext && old.httpStatus == nil && old.apiCode == nil && F.count(F.cover) == beforeNew + 1, "old account model is rejected without transport or leaked observations")
        await other.signOut(); await store.signOut()
        check(SecureVault.values.isEmpty, "synthetic vault cleared on logout")
    }
}
