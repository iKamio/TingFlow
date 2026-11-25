import Foundation

// Standalone executable; link CORE + NCM + NeteaseXEAPIServerFixture.swift.
// No Store, Keychain, sockets, real account material or audio downloads.
private final class NeteaseXEAPITransportFixture: URLProtocol, @unchecked Sendable {
    struct Reply {
        var code = 200
        var cookies: [String] = []
    }
    struct Record {
        let path: String
        let cookies: [String: String]
        let musicHeader: String?
        let payload: [String: Any]
    }
    private static let lock = NSLock()
    private static var holdKeys = false
    private static var keyCookies: [String] = []
    private static var replies: [Reply] = []
    private static var expectedMusicU: String? = "synthetic-quality-fixture"
    private static var pending: [NeteaseXEAPITransportFixture] = []
    private static var records: [Record] = []
    private static var keys = 0
    private static var stoppedKeys = 0
    private static var deliveredKeys = 0
    private static var suppressedKeys = 0
    private static var unexpected = 0
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    private var delivered = false
    private var isKey = false
    private var responseData = Data()
    private var responseCookies: [String] = []

    static func configure(hold: Bool = false, keyCookies: [String] = [], replies: [Reply] = []) {
        lock.lock()
        precondition(pending.isEmpty, "previous synthetic key response must be released")
        holdKeys = hold; self.keyCookies = keyCookies; self.replies = replies
        expectedMusicU = "synthetic-quality-fixture"
        records = []; keys = 0; stoppedKeys = 0; deliveredKeys = 0; suppressedKeys = 0; unexpected = 0
        lock.unlock()
        NeteaseXEAPIServerFixture.reset()
    }
    static func expectMusicU(_ value: String?) { lock.lock(); expectedMusicU = value; lock.unlock() }
    static func snapshot() -> (keys: Int, stopped: Int, delivered: Int, suppressed: Int, unexpected: Int, records: [Record]) {
        lock.lock(); defer { lock.unlock() }
        return (keys, stoppedKeys, deliveredKeys, suppressedKeys, unexpected, records)
    }
    static func releaseKeys() {
        lock.lock(); let waiting = pending; pending = []; lock.unlock()
        // Never invoke URLProtocol callbacks while holding the shared state lock.
        for item in waiting { item.deliver() }
    }
    private static func cookies(_ request: URLRequest) -> [String: String] {
        var result: [String: String] = [:]
        for item in (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";") {
            let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            precondition(pair.count == 2 && result[String(pair[0])] == nil, "unambiguous fixture Cookie")
            result[String(pair[0])] = String(pair[1])
        }
        return result
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "POST", !request.httpShouldHandleCookies,
              url.scheme == "https", url.query == nil else { reject(); return }
        if url == NeteaseWire.xeapiKeyURL {
            deliveryLock.lock(); isKey = true; deliveryLock.unlock()
            do { responseData = try NeteaseXEAPIServerFixture.keyResponse(request) }
            catch { client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData)); return }
            Self.lock.lock()
            Self.keys += 1; responseCookies = Self.keyCookies
            let held = Self.holdKeys
            if held { Self.pending.append(self) }
            Self.lock.unlock()
            if !held { deliver() }
            return
        }
        let xeapi = url.absoluteString == "https://interface3.music.163.com/xeapi/song/enhance/player/url/v1"
        let legacy = url.absoluteString == "https://music.163.com/weapi/song/enhance/player/url"
        let identity = url.absoluteString == "https://interface.music.163.com/eapi/nuser/account/get"
        guard xeapi || legacy || identity else { reject(); return }
        Self.lock.lock(); let expected = Self.expectedMusicU; Self.lock.unlock()
        let payload = xeapi ? NeteaseXEAPIServerFixture.openPayload(request, expectedMusicU: expected) : [:]
        let record = Record(path: url.path, cookies: Self.cookies(request), musicHeader: request.value(forHTTPHeaderField: "x-music-u"), payload: payload)
        Self.lock.lock()
        Self.records.append(record)
        let reply = xeapi && !Self.replies.isEmpty ? Self.replies.removeFirst() : Reply()
        Self.lock.unlock()
        responseCookies = reply.cookies
        let object: [String: Any]
        if identity { object = ["code": 200, "account": ["id": 7], "profile": ["userId": 7, "nickname": "Synthetic transport"]] }
        else { object = ["code": reply.code, "data": [["id": 1, "code": 200, "url": "https://m1.music.126.net/synthetic-transport.mp3", "type": "mp3", "br": 128000, "freeTrialInfo": NSNull()]]] }
        if xeapi { responseData = NeteaseXEAPIServerFixture.encryptedResponse(object) }
        else { responseData = try! JSONSerialization.data(withJSONObject: object) }
        deliver()
    }
    private func reject() {
        Self.lock.lock(); Self.unexpected += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    private func deliver() {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped, !delivered else {
            if isKey && stopped { Self.lock.lock(); Self.suppressedKeys += 1; Self.lock.unlock() }
            return
        }
        delivered = true
        if isKey { Self.lock.lock(); Self.deliveredKeys += 1; Self.lock.unlock() }
        var headers = ["Content-Type": "application/octet-stream"]
        if !responseCookies.isEmpty { headers["Set-Cookie"] = responseCookies.joined(separator: ", ") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped else { return }
        stopped = true
        if isKey && !delivered { Self.lock.lock(); Self.stoppedKeys += 1; Self.lock.unlock() }
    }
}

@main @MainActor struct NeteaseXEAPITransportChecks {
    private static var count = 0
    private static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, "FAIL: " + label); count += 1
    }
    private static func makeClient() throws -> NeteaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeteaseXEAPITransportFixture.self]
        let client = NeteaseClient(configuration: configuration, deviceID: String(repeating: "A", count: 52))
        let cookies = [["name": "MUSIC_U", "value": "synthetic-quality-fixture"],
                       ["name": "MUSIC_A", "value": "synthetic-anonymous"],
                       ["name": "__csrf", "value": "synthetic-csrf-initial"],
                       ["name": "NMTID", "value": "synthetic-nmtid-initial"]]
        try client.restoreCredential(JSONSerialization.data(withJSONObject: ["version": 1, "userID": "7", "cookies": cookies]))
        return client
    }
    private static func savedCookies(_ client: NeteaseClient) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: client.credentialData(userID: "7")) as! [String: Any]
        let rows = object["cookies"] as! [[String: Any]]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as! String, $0["value"] as! String) })
    }
    private static func payload(_ quality: AudioQuality = .high) throws -> [String: Any] {
        try NeteaseAudioPolicy.payload(songID: "1", quality: quality)
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "FAIL: bounded synthetic transport wait timed out")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func cancelled(_ task: Task<[String: Any], Error>, _ label: String) async {
        do { _ = try await task.value; preconditionFailure("FAIL: " + label) }
        catch is CancellationError { count += 1 }
        catch { preconditionFailure("FAIL: expected cancellation, not an underlying error") }
    }
    static func main() async throws {
        try await cookieChecks()
        try await cancelledNegotiationChecks()
        try await invalidationChecks()
        try await singleFlightChecks()
        print("PASS: \(count) XEAPI offline transport checks; no real account, network or audio requests")
    }
    private static func cookieChecks() async throws {
        typealias Fixture = NeteaseXEAPITransportFixture
        let rotated = "synthetic-transport-rotated"
        let keyPoison = [
            "MUSIC_U=synthetic-key-poison; Path=/; Domain=.music.163.com; HttpOnly",
            "__csrf=synthetic-key-csrf; Path=/; Domain=.music.163.com",
            "NMTID=synthetic-key-nmtid; Path=/; Domain=.music.163.com"
        ]
        let valid = [
            "MUSIC_U=\(rotated); Path=/; HttpOnly", // host-only interface3 cookie
            "__csrf=synthetic-csrf-rotated; Path=/; Domain=.music.163.com",
            "NMTID=synthetic-nmtid-rotated; Path=/; Domain=.music.163.com"
        ]
        let forbidden = [
            "MUSIC_U=synthetic-forbidden-lookalike; Path=/; Domain=music.163.com.evil.invalid",
            "MUSIC_U=synthetic-forbidden-subdomain; Path=/; Domain=untrusted.music.163.com",
            "MUSIC_U=synthetic-forbidden-sibling; Path=/; Domain=interface.music.163.com",
            "__csrf=synthetic-forbidden-domain; Path=/; Domain=evil.invalid",
            "MUSIC_A=synthetic-forbidden-parent; Path=/; Domain=163.com",
            "NMTID=synthetic-forbidden-path; Path=/private; Domain=.music.163.com",
            "UNRELATED_SECRET=synthetic-forbidden-name; Path=/; Domain=.music.163.com"
        ]
        let deleteAuxiliary = [
            "__csrf=; Path=/; Domain=.music.163.com; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
            "NMTID=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        ]
        let deleteAuthentication = ["MUSIC_U=; Path=/; Domain=.music.163.com; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"]
        Fixture.configure(keyCookies: keyPoison, replies: [
            .init(cookies: valid), .init(cookies: forbidden), .init(cookies: deleteAuxiliary),
            .init(cookies: deleteAuthentication), .init()
        ])
        let client = try makeClient()
        defer { client.invalidate() }
        let first = try await client.request(.playbackV1, payload())
        _ = try NeteaseMapping.playback(first, songID: "1")
        let beforeRotation = Fixture.snapshot().records[0]
        expect(beforeRotation.cookies["MUSIC_U"] == "synthetic-quality-fixture" && beforeRotation.musicHeader == "synthetic-quality-fixture", "key response cannot replace playback authentication")
        expect(beforeRotation.cookies["__csrf"] == "synthetic-csrf-initial" && beforeRotation.cookies["NMTID"] == "synthetic-nmtid-initial", "key response cannot poison auxiliary account cookies")
        var saved = try savedCookies(client)
        expect(saved["MUSIC_U"] == rotated && saved["__csrf"] == "synthetic-csrf-rotated" && saved["NMTID"] == "synthetic-nmtid-rotated", "successful XEAPI absorbs valid host-only and parent-domain response cookies")
        Fixture.expectMusicU(rotated)
        _ = try await client.request(.playbackV1, payload())
        saved = try savedCookies(client)
        expect(saved["MUSIC_U"] == rotated && saved["__csrf"] == "synthetic-csrf-rotated" && saved["NMTID"] == "synthetic-nmtid-rotated", "lookalike, unrelated domain and non-root path cannot overwrite cookies")
        expect(saved["MUSIC_A"] == "synthetic-anonymous" && saved["UNRELATED_SECRET"] == nil, "broad parent domain and unknown Cookie name rejected")
        _ = try await client.request(.identity)
        let identity = Fixture.snapshot().records.last!
        expect(identity.path == "/eapi/nuser/account/get" && identity.cookies["MUSIC_U"] == rotated && identity.cookies["__csrf"] == "synthetic-csrf-rotated", "rotated XEAPI cookies are shared with this client's EAPI jar")
        _ = try await client.request(.playbackV1, payload())
        saved = try savedCookies(client)
        expect(saved["__csrf"] == nil && saved["NMTID"] == nil && saved["MUSIC_U"] == rotated, "Max-Age zero and comma-bearing Expires delete auxiliary cookies")
        _ = try await client.request(.playbackV1, payload())
        let afterDeletion = Fixture.snapshot().records.last!
        expect(afterDeletion.cookies["__csrf"] == nil && afterDeletion.cookies["NMTID"] == nil, "deleted auxiliary cookies are not resent")
        do { _ = try client.credentialData(userID: "7"); preconditionFailure("FAIL: deleted authentication remained exportable") }
        catch { expect(error as? NeteaseError == .signedOut, "authentication deletion removes exportable session") }
        Fixture.expectMusicU(nil)
        _ = try await client.request(.playbackV1, payload())
        let anonymous = Fixture.snapshot().records.last!
        expect(anonymous.cookies["MUSIC_U"] == nil && anonymous.musicHeader == nil, "deleted MUSIC_U is absent from both Cookie and x-music-u")
        let result = Fixture.snapshot()
        expect(result.keys == 1 && result.records.filter { $0.path.hasPrefix("/xeapi/") }.count == 5, "cookie updates do not cause key renegotiation or playback retries")
        expect(result.unexpected == 0, "every cookie-check request used an exact synthetic route")
    }

    private static func cancelledNegotiationChecks() async throws {
        typealias Fixture = NeteaseXEAPITransportFixture
        Fixture.configure(hold: true)
        let client = try makeClient()
        defer { client.invalidate() }
        let old = Task { @MainActor in try await client.request(.playbackV1, payload(.lossless)) }
        try await waitUntil { Fixture.snapshot().keys == 1 }
        old.cancel()
        let legacy = try await client.request(.playback, NeteaseAudioPolicy.legacyPayload(songID: "1"))
        _ = try NeteaseMapping.playback(legacy, songID: "1")
        expect(client.playbackDiagnostic?.wireProtocol == "WEAPI" && client.playbackDiagnostic?.httpStatus == 200, "explicit legacy request publishes its own success diagnostic")
        Fixture.releaseKeys()
        await cancelled(old, "cancelled negotiating playback must not succeed")
        expect(client.playbackDiagnostic?.wireProtocol == "WEAPI" && client.playbackDiagnostic?.httpStatus == 200 && client.playbackDiagnostic?.businessCode == 200, "late cancelled negotiation cannot overwrite newer WEAPI diagnostic")
        let result = Fixture.snapshot()
        expect(result.keys == 1 && result.records.map(\.path) == ["/weapi/song/enhance/player/url"], "cancelled first caller never sends XEAPI playback after key release")
        expect(result.unexpected == 0, "cancelled request never changes route")
    }
    private static func invalidationChecks() async throws {
        typealias Fixture = NeteaseXEAPITransportFixture
        Fixture.configure(hold: true)
        let oldClient = try makeClient()
        let pending = Task { @MainActor in try await oldClient.request(.playbackV1, payload()) }
        try await waitUntil { Fixture.snapshot().keys == 1 }
        oldClient.invalidate()
        try await waitUntil { Fixture.snapshot().stopped == 1 }
        Fixture.releaseKeys()
        await cancelled(pending, "invalidated negotiating client must not succeed")
        var result = Fixture.snapshot()
        expect(result.delivered == 0 && result.suppressed == 1 && result.records.isEmpty, "stopLoading suppresses invalidated key delivery and all playback")
        expect(oldClient.playbackDiagnostic == nil, "invalidated client cannot republish late diagnostic")
        let fresh = try makeClient()
        defer { fresh.invalidate() }
        let replacement = Task { @MainActor in try await fresh.request(.playbackV1, payload()) }
        try await waitUntil { Fixture.snapshot().keys == 2 }
        Fixture.releaseKeys()
        let object = try await replacement.value
        _ = try NeteaseMapping.playback(object, songID: "1")
        result = Fixture.snapshot()
        expect(result.keys == 2 && result.delivered == 1 && result.records.count == 1, "independent replacement client negotiates its own key after old invalidation")
        expect(fresh.playbackDiagnostic?.wireProtocol == "XEAPI" && fresh.playbackDiagnostic?.httpStatus == 200, "replacement client owns the successful XEAPI diagnostic")
        expect(oldClient.playbackDiagnostic == nil && result.unexpected == 0, "replacement cannot revive invalidated state or use an unexpected route")
    }

    private static func singleFlightChecks() async throws {
        typealias Fixture = NeteaseXEAPITransportFixture
        Fixture.configure(hold: true)
        let client = try makeClient()
        defer { client.invalidate() }
        let first = Task { @MainActor in try await client.request(.playbackV1, payload(.standard)) }
        try await waitUntil { Fixture.snapshot().keys == 1 }
        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return try await client.request(.playbackV1, payload(.lossless))
        }
        try await waitUntil { secondStarted }
        // The second MainActor task runs until its first suspension before this task resumes.
        expect(Fixture.snapshot().keys == 1, "concurrent first callers share in-flight negotiation")
        Fixture.releaseKeys()
        let a = try await first.value
        let b = try await second.value
        _ = try NeteaseMapping.playback(a, songID: "1")
        _ = try NeteaseMapping.playback(b, songID: "1")
        var result = Fixture.snapshot()
        expect(result.keys == 1 && result.records.count == 2, "two concurrent successes require exactly one key request")
        expect(Set(result.records.compactMap { $0.payload["level"] as? String }) == Set(["standard", "lossless"]), "concurrent callers keep separate sealed quality payloads")
        expect(client.playbackDiagnostic?.requestedLevel == "lossless", "latest request owns diagnostic regardless of earlier completion")
        _ = try await client.request(.playbackV1, payload())
        result = Fixture.snapshot()
        expect(result.keys == 1 && result.records.count == 3 && result.unexpected == 0, "verified key reused in this client's memory without hidden requests")
    }
}
