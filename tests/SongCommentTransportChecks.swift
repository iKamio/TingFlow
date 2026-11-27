import Foundation

@main @MainActor struct SongCommentTransportChecks {
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("synthetic URLProtocol did not reach expected state")
    }
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1 }
        let key = "netease.native.weapi.session.v1"
        let song = Song(platform: .netease, platformID: "123456789", title: "Synthetic song", artist: "Synthetic artist", album: "", duration: 60)
        var authClients: [NeteaseClient] = [], anonymousClients = 0
        func client() -> NeteaseClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SongCommentTransportFixture.self]
            return NeteaseClient(configuration: configuration, deviceID: String(repeating: "D", count: 52))
        }
        let make: @MainActor () -> NeteaseClient = { let value = client(); authClients.append(value); return value }
        let makeAnonymous: @MainActor () -> NeteaseClient = { anonymousClients += 1; return client() }
        let store = NeteaseStore(clientFactory: make, anonymousCommentClientFactory: makeAnonymous)
        SongCommentTransportFixture.configure(.normal)
        let anonymous = try await store.comments(for: song, sort: .hot, page: 2, cursor: nil)
        check(anonymous.comments.count == 1 && anonymous.total == 1, "anonymous response decoded, not sample fallback")
        check(SecureVault.reads == 0 && SecureVault.writes == 0 && authClients.isEmpty && anonymousClients == 1, "anonymous comments do not restore or persist login state")
        let request = SongCommentTransportFixture.requested()[0]
        check(request.url.absoluteString == "https://interface.music.163.com/eapi/v2/resource/comments", "only fixed official HTTPS EAPI URL")
        check(!request.authenticated && request.threadID == "R_SO_4_123456789" && request.sort == 2 && request.page == 2 && request.cursor == "normalHot#20", "encrypted wire payload is actual song and hot offset")
        SongCommentTransportFixture.configure(.normal)
        _ = try await store.comments(for: song, sort: .latest, page: 3, cursor: "1700000000000")
        let latest = SongCommentTransportFixture.requested()[0]
        check(latest.sort == 3 && latest.page == 3 && latest.cursor == "1700000000000", "encrypted latest cursor contract")
        var scoped = song; scoped.accountScope = "netease:7"
        let before = SongCommentTransportFixture.requested().count
        do { _ = try await store.comments(for: scoped, sort: .hot, page: 1, cursor: nil); preconditionFailure("stale scoped anonymous request") }
        catch { check(error as? NeteaseError == .signedOut && SongCommentTransportFixture.requested().count == before, "old account song cannot issue an anonymous request") }
        do { _ = try await store.comments(for: song, sort: .latest, page: 2, cursor: nil); preconditionFailure("missing cursor") }
        catch { check(SongCommentTransportFixture.requested().count == before, "invalid pagination rejected before allocating transport") }
        for pair: (SongCommentTransportFixture.Mode, NeteaseError) in [(.signedOut, .signedOut), (.verification, .verification), (.rateLimited, .rateLimited), (.malformed, .response), (.httpFailure, .http(503)), (.oversized, .response)] {
            SongCommentTransportFixture.configure(pair.0)
            do { _ = try await store.comments(for: song, sort: .hot, page: 1, cursor: nil); preconditionFailure("refusal must not become empty comments") }
            catch { check(error as? NeteaseError == pair.1, "transport/business/malformed failure propagated honestly") }
            check(SongCommentTransportFixture.requested().count == 1, "no proxy, automatic retry or login bootstrap")
        }
        SongCommentTransportFixture.configure(.hold)
        let canceled = Task { try await store.comments(for: song, sort: .hot, page: 1, cursor: nil) }
        try await until { SongCommentTransportFixture.requested().count == 1 }
        canceled.cancel()
        do { _ = try await canceled.value; preconditionFailure("canceled anonymous request returned") }
        catch { check(error is CancellationError, "caller cancellation propagates") }
        try await until { SongCommentTransportFixture.stopCount() > 0 }
        check(!store.isSignedIn && SecureVault.writes == 0, "anonymous URLSession cancellation cleaned up without persistence")

        SecureVault.values[key] = try JSONSerialization.data(withJSONObject: ["version": 1, "userID": "7", "cookies": [["name": "MUSIC_U", "value": "synthetic-login-only"]]])
        SongCommentTransportFixture.configure(.normal)
        await store.refresh()
        check(store.isSignedIn && store.scopeID == "netease:7", "authenticated fixture has canonical identity")
        let saved = SecureVault.values[key], writes = SecureVault.writes
        _ = try await store.comments(for: scoped, sort: .hot, page: 1, cursor: nil)
        check(SongCommentTransportFixture.requested().last?.authenticated == true, "verified session comments use account-scoped client")
        check(SecureVault.values[key] == saved && SecureVault.writes == writes, "comment response never saves credentials")
        let credential = try authClients.last!.credentialData(userID: "7")
        let object = try JSONSerialization.jsonObject(with: credential) as! [String: Any]
        let cookies = object["cookies"] as! [[String: Any]]
        check(!cookies.contains { $0["value"] as? String == "synthetic-unwanted-comment-cookie" }, "Set-Cookie from read-only comments not absorbed into account")
        let oldContext = store.commentContextID
        SongCommentTransportFixture.configure(.hold)
        let previousAccount = Task { try await store.comments(for: scoped, sort: .hot, page: 2, cursor: nil) }
        try await until { SongCommentTransportFixture.requested().count == 1 }
        await store.signOut()
        do { _ = try await previousAccount.value; preconditionFailure("page survived sign-out") }
        catch { check(error is CancellationError, "account change cancels in-flight authenticated comments") }
        check(store.commentContextID != oldContext && !store.isSignedIn && SecureVault.values[key] == nil, "account epoch and credential storage cleared")
        try await until { SongCommentTransportFixture.stopCount() > 0 }
        let requestCount = SongCommentTransportFixture.requested().count
        do { _ = try await store.comments(for: scoped, sort: .hot, page: 2, cursor: nil); preconditionFailure("stale account page") }
        catch { check(error as? NeteaseError == .signedOut && SongCommentTransportFixture.requested().count == requestCount, "no stale-account continuation after sign-out") }
        print("PASS: \(count) synthetic song-comment transport/account checks")
    }
}
