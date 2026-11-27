import Foundation

@main struct KugouChecks {
    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) {
        do { let result = try value(); precondition(result, "Kugou check failed: " + label) }
        catch { preconditionFailure("Kugou check threw: " + label) }
    }
    static func rejects(_ label: String, _ block: () throws -> Void) {
        do { try block(); preconditionFailure("Expected rejection: " + label) } catch { }
    }
    @MainActor static func main() async throws {
        let device = KugouDevice(mid: "123456789012345678", dev: String(repeating: "A", count: 32))
        let c = try KugouCredential(userID: "42", token: "synthetic-token", device: device)
        expect((0..<200).allSatisfy { _ in KugouDevice.fresh().isValid }, "fresh device always validates")
        let params = ["appid": "1001", "clienttime": "1700000000", "mid": "12345678"]
        expect(KugouCrypto.signature(params, kind: .web) == "010c2efb8355bbbe23a9febcbfc02948", "web independent MD5 vector")
        let body = try KugouCrypto.json([("userid", .number("42")), ("token", .string("synthetic-token"))])
        expect(String(data: body, encoding: .utf8) == "{\"userid\":42,\"token\":\"synthetic-token\"}", "ordered exact JSON bytes")
        expect(KugouCrypto.signature(["appid": "1005", "userid": "42"], body: body, kind: .android) == "52386dbe51fdbd11eee0dde98eb17e3d", "android body included")
        rejects("unsafe JSON numeric precision") { _ = try KugouCrypto.json([("id", .number("9007199254740992"))]) }
        for invalid: Any in [true, -1, 1.5, "01", "1e3", "１２"] { expect(KugouMapping.decimal(invalid) == nil, "canonical decimal") }
        let transport = KugouFixtureTransport()
        let client = KugouClient(transport: transport, now: { Date(timeIntervalSince1970: 1700000000) })
        _ = try await client.qrKey(device: device)
        let r = transport.requests[0]
        expect(r.httpShouldHandleCookies == false && r.value(forHTTPHeaderField: "Cookie") == nil, "no cookie sharing")
        let query = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.first { $0.name == "appid" }?.value == "1014", "QR generation web appid override")
        expect(query.first { $0.name == "srcappid" }?.value == "2919", "standard source app")
        expect(!query.contains { $0.name == "token" || $0.name == "userid" }, "QR starts anonymous")
        for bad in ["http://gateway.kugou.com/v3/get_my_info", "https://u@gateway.kugou.com/v3/get_my_info", "https://gateway.kugou.com:443/v3/get_my_info", "https://gateway.kugou.com.evil.invalid/v3/get_my_info", "https://gateway.kugou.com/v1/cloud_mutation", "https://127.0.0.1/v3/get_my_info"] {
            expect(!KugouHTTPS.isAllowed(URL(string: bad)!), "exact HTTPS origin/path policy")
        }
        for status in [0, 1, 2, 4] {
            let root: [String: Any] = ["data": ["status": status, "userid": 42, "token": "synthetic-token"]]
            let result = try KugouMapping.qrResult(root, device: device)
            if case .authorized(let value) = result { expect(status == 4 && value.userID == "42", "authorization only from state four") }
        }
        rejects("unknown QR state") { _ = try KugouMapping.qrResult(["data": ["status": 3]], device: device) }
        rejects("profile identity mismatch") { _ = try KugouMapping.profile(["data": ["userid": 99]], expected: "42") }
        expect(KugouMapping.artwork("https://imge.kugou.com/a.jpg?token=synthetic") == nil, "no signed artwork metadata")
        let mapped = try KugouMapping.tracks(["data": ["info": [["hash": String(repeating: "b", count: 32), "mixsongid": 77, "filename": "Artist - Title", "timelen": 3500]], "total": 1]], scope: "kugou:42")
        expect(mapped.items[0].platform == .kugou && mapped.items[0].platformID == "77" && mapped.items[0].hash == String(repeating: "B", count: 32), "LX MixSongID plus original hash")
        expect(mapped.items[0].accountScope == "kugou:42" && mapped.items[0].duration == 3.5, "account scoped song duration")
        var window = KugouPageWindow(pageSize: 2)
        expect(try window.accept(KugouPage(items: [1, 2], total: 3, rawCount: 2, fingerprint: "a")), "full first page")
        expect(try !window.accept(KugouPage(items: [3], total: 3, rawCount: 1, fingerprint: "b")), "complete short last page")
        var repeatWindow = KugouPageWindow(pageSize: 1)
        _ = try repeatWindow.accept(KugouPage(items: [1], total: 3, rawCount: 1, fingerprint: "a"))
        rejects("repeated page") { _ = try repeatWindow.accept(KugouPage(items: [1], total: 3, rawCount: 1, fingerprint: "a")) }
        var emptyWindow = KugouPageWindow(pageSize: 2)
        rejects("early empty page") { _ = try emptyWindow.accept(KugouPage<Int>(items: [], total: 3, rawCount: 0, fingerprint: "")) }
        let instant = Date(timeIntervalSince1970: 1000)
        var qr = KugouQRWindow(now: instant)
        qr.pause(); expect(!qr.beginCheck(now: instant), "background never polls")
        expect(qr.resume(now: instant.addingTimeInterval(119)), "foreground can resume within deadline")
        expect(!qr.resume(now: instant.addingTimeInterval(120)), "background never extends hard deadline")
        transport.response = ["status": 0, "error_code": 999, "message": "secret-server-message-synthetic-token"]
        do { _ = try await client.qrKey(device: device); preconditionFailure("server error accepted") }
        catch { expect(!KugouError.message(error).contains("secret-server"), "no raw server messages") }
        transport.raw = Data(repeating: 32, count: KugouHTTPS.maximumBytes + 1)
        do { _ = try await client.qrKey(device: device); preconditionFailure("oversize accepted") } catch { }
        try await protocolChecks(c)
        try await storeChecks(c)
        print("Kugou synthetic protocol/lifecycle checks passed (no network or real account).")
    }
    @MainActor static func storeChecks(_ c: KugouCredential) async throws {
        let api = KugouFixtureAPI(), vault = try KugouMemoryVault(c)
        let store = KugouStore(client: api, vault: vault)
        expect(!store.isSignedIn && api.qrCalls == 0, "no pretend account or implicit QR")
        await store.restore()
        expect(store.accountScope == "kugou:42" && store.playlists.count == 102, "local ID-only restore reads all playlist pages")
        let list = store.playlists[0]
        let songs = try await store.tracks(in: list)
        expect(songs.count == 2 && songs[0].id == songs[1].id, "repeated track positions preserved")
        _ = try await store.tracks(in: list)
        expect(api.trackCalls == 1, "ordinary reads reuse complete cache")
        api.failTracks = true
        do { _ = try await store.tracks(in: list, forceReload: true); preconditionFailure("forced read returned stale cache") }
        catch { expect(error as? KugouError == .rejected, "forced read surfaces sanitized failure") }
        expect(api.trackCalls == 2, "explicit reread reaches client despite populated cache")
        api.failTracks = false
        _ = try await store.tracks(in: list, forceReload: true)
        expect(api.trackCalls == 3, "retry after failed forced read reaches client")
        _ = try await store.tracks(in: list)
        expect(api.trackCalls == 3, "successful retry restores normal cache behavior")
        api.failLists = true; await store.refresh()
        expect(store.playlists.count == 102 && store.errorMessage != nil, "failed read does not replace good snapshot")
        store.signOut()
        expect(!store.isSignedIn && store.playlists.isEmpty && vault.data == nil, "sign out clears scope caches and vault")
        do { _ = try await store.tracks(in: list); preconditionFailure("stale list accepted") } catch { }
        await store.restore(); expect(!store.isSignedIn, "sign out disables implicit restore")

        let lateAPI = KugouFixtureAPI(), lateVault = try KugouMemoryVault(c)
        lateAPI.holdLists = true
        let lateStore = KugouStore(client: lateAPI, vault: lateVault)
        let restoring = Task { await lateStore.restore() }
        for _ in 0..<1000 { if lateAPI.heldLists != nil { break }; await Task.yield() }
        expect(lateAPI.heldLists != nil, "restore reached synthetic list gate")
        lateStore.signOut()
        lateAPI.heldLists?.resume(); lateAPI.heldLists = nil
        await restoring.value
        expect(!lateStore.isSignedIn && lateVault.data == nil, "late identity cannot resurrect signed-out account")

        let trackAPI = KugouFixtureAPI(), trackVault = try KugouMemoryVault(c)
        let trackStore = KugouStore(client: trackAPI, vault: trackVault)
        await trackStore.restore(); trackAPI.holdTracks = true
        let oldList = trackStore.playlists[0]
        let reading = Task { try await trackStore.tracks(in: oldList) }
        for _ in 0..<1000 { if trackAPI.heldTracks != nil { break }; await Task.yield() }
        expect(trackAPI.heldTracks != nil, "track request reached synthetic gate")
        trackStore.signOut(); trackAPI.heldTracks?.resume(); trackAPI.heldTracks = nil
        do { _ = try await reading.value; preconditionFailure("late tracks accepted") } catch { }
        expect(trackStore.accountScope == nil, "late tracks cannot cross account generation")

        let qrAPI = KugouFixtureAPI(), qrVault = try KugouMemoryVault()
        let qrStore = KugouStore(client: qrAPI, vault: qrVault)
        qrStore.setForeground(false); qrStore.startQRCodeLogin()
        expect(!qrStore.isAuthorizing && qrAPI.qrCalls == 0, "background cannot initiate QR")
        qrStore.setForeground(true); qrStore.startQRCodeLogin()
        for _ in 0..<1000 { if qrStore.qrURL != nil { break }; await Task.yield() }
        expect(qrStore.isAuthorizing && qrStore.qrURL != nil, "only explicit QR action creates code")
        qrStore.cancelQRCodeLogin()
        expect(qrStore.qrURL == nil && !qrStore.isSignedIn && qrVault.saves == 0, "cancel never manufactures login or persists token")

        let wrongAPI = KugouFixtureAPI(), wrongVault = try KugouMemoryVault(c)
        wrongAPI.foreignScope = true
        let wrongStore = KugouStore(client: wrongAPI, vault: wrongVault)
        await wrongStore.restore()
        expect(wrongStore.playlists.isEmpty && wrongStore.errorMessage != nil, "cross-account list data fails closed")

        let loginAPI = KugouFixtureAPI(), loginVault = try KugouMemoryVault()
        let loginStore = KugouStore(client: loginAPI, vault: loginVault)
        loginStore.startQRCodeLogin()
        for _ in 0..<60 {
            if loginStore.isSignedIn && loginStore.playlists.count == 102 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        expect(loginStore.isSignedIn && loginVault.saves == 1 && loginStore.qrURL == nil, "verified real QR state commits once and erases QR")
        expect(loginStore.playlists.count == 102, "successful QR commit does not self-cancel refresh")
        loginStore.signOut()

        let pendingAPI = KugouFixtureAPI(), pendingVault = try KugouMemoryVault()
        pendingAPI.holdKey = true
        let pendingStore = KugouStore(client: pendingAPI, vault: pendingVault)
        pendingStore.startQRCodeLogin()
        for _ in 0..<1000 { if pendingAPI.heldKey != nil { break }; await Task.yield() }
        expect(pendingAPI.heldKey != nil && pendingVault.saves == 0 && !pendingStore.isSignedIn, "pending anonymous request cannot authenticate")
        pendingStore.cancelQRCodeLogin()
        pendingAPI.heldKey?.resume(); pendingAPI.heldKey = nil
        for _ in 0..<100 { await Task.yield() }
        expect(!pendingStore.isSignedIn && pendingVault.saves == 0, "cancel blocks late QR key response")
        try await boundedQRChecks()
    }
}

extension KugouChecks {
    @MainActor static func boundedQRChecks() async throws {
        // Poll sleeps yield immediately; the expiry sleeper is always cancelled by test teardown.
        let fast: (UInt64) async throws -> Void = { delay in
            if delay == 120_000_000_000 { try await Task.sleep(nanoseconds: delay) }
            else { await Task.yield(); try Task.checkCancellation() }
        }
        let at = Date(timeIntervalSince1970: 1000)
        for authorization in [48, 49] {
            let api = KugouFixtureAPI(), vault = try KugouMemoryVault()
            api.authorizeAt = authorization
            let store = KugouStore(client: api, vault: vault, now: { at }, sleep: fast)
            store.startQRCodeLogin()
            for _ in 0..<5000 { if !store.isAuthorizing { break }; await Task.yield() }
            expect(!store.isAuthorizing && api.checkCalls == 48, "never issue poll 49")
            expect(store.isSignedIn == (authorization == 48), "48th response may authorize but 49th never can")
            expect(vault.saves == (authorization == 48 ? 1 : 0), "persist once only for authorized state")
            store.signOut()
        }
        var current = at
        let api = KugouFixtureAPI(), vault = try KugouMemoryVault()
        api.authorizeAt = 99
        let store = KugouStore(client: api, vault: vault, now: { current }, sleep: fast)
        store.startQRCodeLogin()
        for _ in 0..<1000 { if store.qrURL != nil { break }; await Task.yield() }
        store.setForeground(false)
        let before = api.checkCalls
        for _ in 0..<100 { await Task.yield() }
        expect(api.checkCalls == before, "inactive cancels polling and makes no new requests")
        current = at.addingTimeInterval(120)
        store.setForeground(true)
        expect(!store.isAuthorizing && store.qrURL == nil && vault.saves == 0, "background never extends deadline")
        store.signOut()
        let oldDevice = KugouDevice(mid: "123456789012345678", dev: String(repeating: "A", count: 32))
        let old = try KugouCredential(userID: "8", token: "synthetic-old-token", device: oldDevice)
        let failedAPI = KugouFixtureAPI(), failedVault = try KugouMemoryVault(old)
        let failedStore = KugouStore(client: failedAPI, vault: failedVault, now: { at }, sleep: fast)
        await failedStore.restore(); failedVault.failSave = true
        failedStore.startQRCodeLogin()
        for _ in 0..<2000 { if !failedStore.isAuthorizing { break }; await Task.yield() }
        expect(failedStore.accountScope == "kugou:8" && failedVault.saves == 0, "failed replacement vault save keeps old account")
        failedVault.failRemove = true; failedStore.signOut()
        expect(failedStore.accountScope == nil && failedStore.errorMessage != nil && failedStore.credentialRemovalPending, "failed vault deletion clears memory but preserves UI retry state")
        failedStore.startQRCodeLogin(); failedStore.cancelQRCodeLogin()
        expect(failedStore.credentialRemovalPending && failedVault.data != nil, "unrelated QR start/cancel cannot hide pending credential deletion")
        failedVault.failRemove = false; failedStore.signOut()
        expect(!failedStore.credentialRemovalPending && failedVault.data == nil, "user-accessible retry clears saved credential and pending state")
        let freshStore = KugouStore(client: failedAPI, vault: failedVault, now: { at }, sleep: fast)
        await freshStore.restore()
        expect(!freshStore.isSignedIn, "fresh store cannot restore deleted account")
    }
}

extension KugouChecks {
    @MainActor static func protocolChecks(_ credential: KugouCredential) async throws {
        struct Vector: Decodable {
            let name: String
            let parameters: [String: String]
            let body: String
            let kind: String
            let signature: String
        }
        let fixture = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/fixtures/KugouSignatureVectors.json"
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
        for v in vectors {
            expect(KugouCrypto.signature(v.parameters, body: Data(v.body.utf8), kind: v.kind == "web" ? .web : .android) == v.signature, "reference signature " + v.name)
        }
        let wire = KugouFixtureTransport()
        let client = KugouClient(transport: wire, now: { Date(timeIntervalSince1970: 1700000000) })
        _ = try await client.qrKey(device: credential.device)
        wire.response = ["status": 1, "data": ["status": 1]]
        _ = try await client.checkQR("synthetic-key", device: credential.device)
        wire.response = ["status": 1, "error_code": 0, "data": ["info": [], "total": 0]]
        _ = try await client.playlists(credential, page: 1, size: 100)
        _ = try await client.tracks(credential, listID: "9", page: 1, size: 100)
        let paths = ["/v2/qrcode", "/v2/get_userinfo_qrcode", "/v7/get_all_list", "/v4/get_list_all_file_v3"]
        for (index, request) in wire.requests.enumerated() {
            let expected = vectors[index]
            let c = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
            var signed = expected.parameters; signed["signature"] = expected.signature
            expect(query == signed, "exact signed query: " + expected.name)
            expect(c.path == paths[index] && c.scheme == "https", "only exact official operation")
            expect(request.httpBody == (expected.body.isEmpty ? nil : Data(expected.body.utf8)), "signed body bytes equal transmitted bytes")
            expect(KugouHTTPS.isAllowed(request) && !request.httpShouldHandleCookies, "safe method/router/cookie policy")
            var mutated = request; mutated.setValue("synthetic", forHTTPHeaderField: "Cookie")
            expect(!KugouHTTPS.isAllowed(mutated), "refuse explicit cookie")
            mutated = request; mutated.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
            expect(!KugouHTTPS.isAllowed(mutated), "refuse unrelated authorization")
            mutated = request; mutated.httpMethod = "DELETE"
            expect(!KugouHTTPS.isAllowed(mutated), "refuse mutation methods")
        }
        for bad in ["https://gateway.kugou.com/v3/get_my_info", "https://login-user.kugou.com/v2/qrcode/", "https://login-user.kugou.com/%762/qrcode", "https://gateway.kugou.com/v7/get_all_list#fragment"] {
            expect(!KugouHTTPS.isAllowed(URL(string: bad)!), "no extra routes/encoded paths/fragments")
        }
        let url = try KugouMapping.qrURL("synthetic-key")
        expect(url.absoluteString == "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=synthetic-key", "native QR payload is official H5 URL")
        rejects("unsafe QR key never rendered") { _ = try KugouMapping.qrURL("key&token=synthetic") }
        rejects("malformed credential never accepted") { _ = try KugouCredential(userID: "0", token: "synthetic", device: credential.device) }
        rejects("token header characters blocked") { _ = try KugouCredential(userID: "42", token: "synthetic\nsecret", device: credential.device) }
        let mapped = try KugouMapping.playlists(["data": ["info": [
            ["listid": 9, "name": "Created", "list_create_userid": 42],
            ["listid": 10, "name": "Collected", "list_create_userid": 7],
            ["listid": 11, "name": "Unknown"]], "total": 3]], uid: "42")
        expect(mapped.items.map(\.kind) == [.created, .collected, .unknown], "created/collected distinction does not invent owner")
        let ambiguous = try KugouMapping.playlists(["data": ["info": [["listid": 9, "name": "Page row"]], "count": 1]], uid: "42")
        expect(ambiguous.total == nil, "unverified count does not pretend account-wide total")
        var qr = KugouQRWindow(now: Date(timeIntervalSince1970: 0))
        for _ in 0..<48 { expect(qr.beginCheck(now: Date(timeIntervalSince1970: 1)), "one of 48 permitted checks") }
        expect(qr.live(now: Date(timeIntervalSince1970: 1)) && !qr.beginCheck(now: Date(timeIntervalSince1970: 1)), "48th response remains live but check 49 denied")
        var page = KugouPageWindow(pageSize: 1, maxPages: 1)
        rejects("unknown total cannot silently truncate at cap") { _ = try page.accept(KugouPage(items: [1], total: nil, rawCount: 1, fingerprint: "one")) }
    }
}
