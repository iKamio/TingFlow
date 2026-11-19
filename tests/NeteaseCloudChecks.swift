import Foundation

/// Standalone macOS executable; synthetic URLProtocol replaces every network request.
@main @MainActor struct NeteaseCloudChecks {
    static var count = 0
    static let likeRead = "/eapi/song/like/get"
    static let likeWrite = "/eapi/radio/like"
    static let listsRead = "/eapi/user/playlist"
    static let detailRead = "/eapi/v6/playlist/detail"
    static let addWrite = "/eapi/playlist/manipulate/tracks"
    static func expect(_ value: Bool, _ label: String) {
        precondition(value, "FAIL: \(label)"); count += 1
    }
    static func writes() -> Int { NeteaseCloudFixture.requests().filter { NeteaseCloudFixture.isWrite($0.path) }.count }
    static func paths(since index: Int) -> [String] { NeteaseCloudFixture.requests().dropFirst(index).map(\.path) }
    static func song(_ id: String, scope: String? = "netease:7", platform: MusicPlatform = .netease) -> Song {
        Song(platform: platform, platformID: id, title: "Synthetic song", artist: "Fixture", album: "", duration: 1, accountScope: scope)
    }
    static func list(_ id: String, owner: String? = "8", scope: String = "netease:7") -> NeteasePlaylist {
        NeteasePlaylist(id: id, name: "Synthetic list", trackCount: 0, coverURL: nil,
                       ownerName: "Fixture", accountScope: scope, ownerID: owner)
    }
    static func fails(_ expected: NeteaseCloudFailure, _ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("FAIL: expected cloud failure") }
        catch { expect(error as? NeteaseCloudFailure == expected, "typed cloud failure \(expected)") }
    }
    static func rejected(_ expected: NeteaseError, _ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("FAIL: expected definitive rejection") }
        catch { expect(error as? NeteaseError == expected, "typed platform rejection") }
    }
    static func seedVault() throws {
        // This never reads real environment variables or accesses Keychain.
        let object: [String: Any] = ["version": 1, "userID": "7", "cookies": [
            ["name": "MUSIC_U", "value": "synthetic-cloud-session"],
            ["name": "__csrf", "value": "synthetic-cloud-csrf"],
            ["name": "OTHER_SECRET", "value": "fixture-extra"]]]
        SecureVault.values["netease.native.weapi.session.v1"] = try JSONSerialization.data(withJSONObject: object)
    }
    static func main() async throws {
        let make: @MainActor () -> NeteaseClient = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NeteaseCloudFixture.self]
            return NeteaseClient(configuration: configuration, deviceID: String(repeating: "B", count: 52))
        }
        try seedVault()
        let store = NeteaseStore(clientFactory: make)
        expect(!store.hasLoadedLikes && store.likedSongIDs.isEmpty, "no fabricated initial cloud likes")
        await store.refresh()
        expect(store.isSignedIn && store.scopeID == "netease:7", "canonical synthetic identity restored")
        await store.refreshCloudLikes()
        await store.refreshCloudPlaylists()
        expect(writes() == 0, "login, recommendations and cloud refresh are read-only")
        expect(store.hasLoadedLikes && !store.isLoadingLikes && store.likedSongIDs.isEmpty, "confirmed empty likes")
        let one = song("11")
        var mark = NeteaseCloudFixture.requests().count
        try await store.setCloudLiked(one, liked: true)
        expect(paths(since: mark) == [likeRead, likeWrite, likeRead], "like has fresh precheck and post-write proof")
        expect(store.isCloudLiked(one) && store.cloudPending.isEmpty, "heart only after confirmation")
        let payload = NeteaseCloudFixture.requests().first { $0.path == likeWrite }!.payload
        expect(payload["alg"] as? String == "itembased" && payload["trackId"] as? String == "11" &&
               payload["like"] as? String == "true" && payload["time"] as? String == "3", "exact decrypted like payload")
        mark = NeteaseCloudFixture.requests().count
        try await store.setCloudLiked(one, liked: true)
        expect(paths(since: mark) == [likeRead], "desired state no-op still reads fresh proof")
        mark = NeteaseCloudFixture.requests().count
        try await store.setCloudLiked(one, liked: false)
        expect(paths(since: mark) == [likeRead, likeWrite, likeRead] && !store.isCloudLiked(one), "unlike confirmed by readback")
        expect(NeteaseCloudFixture.requests().last(where: { $0.path == likeWrite })?.payload["like"] as? String == "false", "explicit unlike flag")
        try await checkPlaylists(store)
        try await checkAmbiguity(store)
        try await checkIsolation(store, make: make)
        expect(NeteaseCloudFixture.requests().allSatisfy(\.safeWire), "only official encrypted API; no unrelated cookie")
        print("PASS: \(count) Netease cloud fixture checks; no real accounts or network writes")
    }
    static func checkPlaylists(_ store: NeteaseStore) async throws {
        let own = store.createdPlaylists.first { $0.id == "101" }!
        expect(own.isPrivate, "private own playlist discovered")
        var mark = NeteaseCloudFixture.requests().count
        try await store.addCloudSong(song("12"), to: own)
        expect(paths(since: mark) == [detailRead, addWrite, detailRead], "private own add uses fresh ownership and readback")
        expect(store.playlists.first { $0.id == "101" }?.trackCount == 2, "only confirmed playlist count published")
        let payload = NeteaseCloudFixture.requests().last { $0.path == addWrite }!.payload
        expect(payload["op"] as? String == "add" && payload["pid"] as? String == "101" &&
               payload["trackIds"] as? String == "[12]" && payload["imme"] as? String == "true", "single ID JSON add payload")
        mark = NeteaseCloudFixture.requests().count
        try await store.addCloudSong(song("12"), to: own)
        expect(paths(since: mark) == [detailRead], "existing track never repeats POST")
        let before = writes()
        // Lie in the view snapshot: the fresh creator is 8 and must win.
        await fails(.notOwner) { try await store.addCloudSong(song("13"), to: list("102", owner: "7")) }
        await fails(.notOwner) { try await store.setCloudPlaylistSubscribed(own, subscribed: false) }
        await fails(.notOwner) { try await store.setCloudPlaylistSubscribed(own, subscribed: true) }
        await fails(.invalidInput) { try await store.addCloudSong(song("13", scope: "netease:8"), to: own) }
        await fails(.invalidInput) { try await store.setCloudLiked(song("13", platform: .local), liked: true) }
        await fails(.invalidInput) { try await store.setCloudLiked(song("0"), liked: true) }
        await fails(.invalidInput) { try await store.setCloudPlaylistSubscribed(list("103", scope: "netease:8"), subscribed: true) }
        expect(writes() == before, "foreign, stale-scope and invalid input never mutate")
        let foreign = list("103")
        mark = NeteaseCloudFixture.requests().count
        try await store.setCloudPlaylistSubscribed(foreign, subscribed: true)
        expect(paths(since: mark) == [detailRead, listsRead, "/eapi/playlist/subscribe", listsRead], "subscribe requires complete user-list proof")
        expect(store.subscribedPlaylists.contains { $0.id == "103" }, "subscription confirmed")
        mark = NeteaseCloudFixture.requests().count
        try await store.setCloudPlaylistSubscribed(foreign, subscribed: true)
        expect(paths(since: mark) == [detailRead, listsRead], "already subscribed has no POST")
        mark = NeteaseCloudFixture.requests().count
        try await store.setCloudPlaylistSubscribed(foreign, subscribed: false)
        expect(paths(since: mark) == [detailRead, listsRead, "/eapi/playlist/unsubscribe", listsRead], "unsubscribe confirmed by absence")
        expect(!store.playlists.contains { $0.id == "103" }, "confirmed removal published")
        NeteaseCloudFixture.configure(.duplicate512)
        let duplicateMark = writes()
        await rejected(.business(512)) { try await store.addCloudSong(song("14"), to: own) }
        expect(writes() == duplicateMark + 1 && !store.cloudNeedsReview.contains("tracks:101"), "512 rejected once; never double IDs or auto-retry")
        NeteaseCloudFixture.configure(.risk)
        let riskMark = writes()
        await rejected(.verification) { try await store.setCloudLiked(song("15"), liked: true) }
        expect(writes() == riskMark + 1 && !store.isCloudLiked(song("15")), "risk response not retried or optimistically liked")
        expect(store.cloudMessage?.contains("fixture-private") == false, "raw rejection text never published")
    }

    static func checkAmbiguity(_ store: NeteaseStore) async throws {
        let uncertain = song("21")
        NeteaseCloudFixture.configure(.timeoutAfterApply)
        let before = writes()
        await fails(.unconfirmed) { try await store.setCloudLiked(uncertain, liked: true) }
        expect(writes() == before + 1 && !store.isCloudLiked(uncertain), "applied timeout keeps last confirmed heart")
        expect(store.cloudNeedsReview.contains("like:21") && store.cloudPending.isEmpty, "unknown result locks target and finishes spinner")
        await fails(.needsRefresh) { try await store.setCloudLiked(uncertain, liked: true) }
        expect(writes() == before + 1, "unknown target cannot repeat POST")
        await store.refreshCloudLikes()
        expect(store.isCloudLiked(uncertain) && !store.cloudNeedsReview.contains("like:21"), "manual read reconciles applied write")
        try await store.setCloudLiked(uncertain, liked: true)
        expect(writes() == before + 1, "retry after reconciliation is verified no-op")
        NeteaseCloudFixture.configure(.readDenyAfterApply)
        await fails(.unconfirmed) { try await store.setCloudLiked(song("22"), liked: true) }
        let snapshot = store.likedSongIDs
        await store.refreshCloudLikes()
        expect(store.likedSongIDs == snapshot && store.hasLoadedLikes && store.cloudNeedsReview.contains("like:22"), "failed reconciliation preserves snapshot and lock")
        expect(!store.isCloudLiked(song("22")), "write success without readable proof never fills heart")
        NeteaseCloudFixture.configure()
        await store.refreshCloudLikes()
        expect(store.isCloudLiked(song("22")), "read recovery publishes actual state")
        NeteaseCloudFixture.configure(.mismatchAfterApply)
        await fails(.unconfirmed) { try await store.setCloudLiked(song("23"), liked: true) }
        expect(!store.isCloudLiked(song("23")) && store.cloudNeedsReview.contains("like:23"), "code 200 with mismatched readback remains unconfirmed")
        await store.refreshCloudLikes()
        expect(!store.cloudNeedsReview.contains("like:23"), "explicit read clears mismatch lock without writing")
        NeteaseCloudFixture.configure(.http503AfterApply)
        await fails(.unconfirmed) { try await store.setCloudLiked(song("24"), liked: true) }
        expect(store.cloudNeedsReview.contains("like:24") && !store.isCloudLiked(song("24")), "5xx after apply is ambiguous")
        await store.refreshCloudLikes()
        expect(store.isCloudLiked(song("24")), "5xx state reconciled without retry")
        NeteaseCloudFixture.configure(.timeoutAfterApply)
        let foreign = list("103"), subscriptionWrites = writes()
        await fails(.unconfirmed) { try await store.setCloudPlaylistSubscribed(foreign, subscribed: true) }
        expect(!store.playlists.contains { $0.id == "103" } && store.cloudNeedsReview.contains("playlist:103"), "subscription timeout keeps confirmed lists")
        await fails(.needsRefresh) { try await store.setCloudPlaylistSubscribed(foreign, subscribed: true) }
        await store.refreshCloudPlaylists()
        expect(writes() == subscriptionWrites + 1 && store.playlists.contains { $0.id == "103" } &&
               !store.cloudNeedsReview.contains("playlist:103"), "playlist refresh reconciles without POST")
        let own = list("104", owner: "7"), addCount = writes()
        NeteaseCloudFixture.configure(.timeoutAfterApply)
        await fails(.unconfirmed) { try await store.addCloudSong(song("25"), to: own) }
        await fails(.needsRefresh) { try await store.addCloudSong(song("25"), to: own) }
        let mark = NeteaseCloudFixture.requests().count
        await store.refreshCloudPlaylists()
        expect(paths(since: mark) == [listsRead, detailRead] && !store.cloudNeedsReview.contains("tracks:104"), "track lock requires fresh full detail reconciliation")
        try await store.addCloudSong(song("25"), to: own)
        expect(writes() == addCount + 1, "reconciled existing track never duplicates add")
        // Cancellation while still signed in after a submitted POST must lock the target.
        NeteaseCloudFixture.configure(.holdReadAfterApply)
        let cancellationWrites = writes()
        let cancelledWrite = Task { try await store.setCloudLiked(song("26"), liked: true) }
        try await waitForHeldRead()
        expect(!store.isCloudLiked(song("26")) && store.cloudPending.contains("like:26"), "no optimistic heart while post-write read is suspended")
        await fails(.busy) { try await store.setCloudLiked(song("27"), liked: true) }
        cancelledWrite.cancel()
        NeteaseCloudFixture.releaseRead()
        do { try await cancelledWrite.value; preconditionFailure("FAIL: cancelled write unexpectedly confirmed") }
        catch { expect(error as? NeteaseCloudFailure == .unconfirmed, "post-write cancellation is ambiguous") }
        expect(store.cloudNeedsReview.contains("like:26") && writes() == cancellationWrites + 1, "cancelled write locks resource without replay")
        await store.refreshCloudLikes()
        expect(store.isCloudLiked(song("26")) && !store.cloudNeedsReview.contains("like:26"), "manual read reconciles cancelled write")
        expect(!store.isCloudLiked(song("21", scope: "netease:8")) &&
               !store.isCloudLiked(song("21", platform: .local)), "heart is current-account/platform only")
        expect((try NeteaseCloudPolicy.likedIDs(["ids": [1, "2", "2"]])) == Set(["1", "2"]), "positive validated likes set")
        let invalidIDs: [Any] = [true, 0, -1, "1x"]
        for invalid in invalidIDs {
            do { _ = try NeteaseCloudPolicy.likedIDs(["ids": [invalid]]); preconditionFailure("FAIL: malformed liked ID") }
            catch { expect(error as? NeteaseError == .response, "malformed IDs fail closed") }
        }
    }

    static func waitForHeldRead() async throws {
        for _ in 0..<300 {
            if NeteaseCloudFixture.hasHeldRead() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("FAIL: fixture request did not arrive")
    }
    static func checkIsolation(_ store: NeteaseStore, make: @escaping @MainActor () -> NeteaseClient) async throws {
        NeteaseCloudFixture.configure()
        NeteaseCloudFixture.holdLikes()
        let pending = Task { await store.refreshCloudLikes() }
        try await waitForHeldRead()
        expect(store.isLoadingLikes, "read loading published")
        let before = writes()
        await fails(.busy) { try await store.setCloudLiked(song("31"), liked: true) }
        expect(writes() == before, "concurrent read excludes mutation")
        await store.signOut()
        // Cancellation closes the real transport; even a fixture late reply cannot restore state.
        NeteaseCloudFixture.releaseRead()
        await pending.value
        expect(!store.isSignedIn && store.scopeID == nil && store.likedSongIDs.isEmpty && !store.hasLoadedLikes,
               "logout prevents late cloud snapshot resurrection")
        expect(store.cloudPending.isEmpty && store.cloudNeedsReview.isEmpty && !store.isLoadingLikes && store.cloudMessage == nil,
               "logout clears every cloud state flag")
        expect(SecureVault.values.isEmpty, "synthetic session deleted")
        await fails(.invalidAccount) { try await store.setCloudLiked(song("31"), liked: true) }
        expect(writes() == before, "signed-out writes never reach transport")
        try seedVault()
        let newStore = NeteaseStore(clientFactory: make)
        await newStore.refresh()
        expect(!newStore.hasLoadedLikes && newStore.likedSongIDs.isEmpty, "new session does not inherit old likes snapshot")
        await newStore.signOut()
    }
}
