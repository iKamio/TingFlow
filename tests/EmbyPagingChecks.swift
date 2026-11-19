import Foundation

@main struct EmbyPagingChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, "FAIL: \(label)"); checks += 1 }
        func fails(_ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("FAIL: \(label)") } catch { checks += 1 }
        }
        var large = EmbyCursor()
        try large.accept(count: 100, reportedTotal: 25_001, fingerprint: "page-0")
        expect(large.nextIndex == 100 && large.total == 25_001 && large.hasMore, "large total must not reject first page")
        for page in 1...200 {
            try large.accept(count: 100, reportedTotal: 25_001, fingerprint: "page-\(page)")
        }
        expect(large.nextIndex == 20_100 && large.hasMore, "more than 100 pages remains usable")
        let roundTrip = try JSONDecoder().decode(EmbyCursor.self, from: JSONEncoder().encode(large))
        expect(roundTrip == large, "range cache round trip")
        var repeated = EmbyCursor()
        try repeated.accept(count: 100, reportedTotal: 20_000, fingerprint: "identical")
        let before = repeated
        fails("detect repeated page") { try repeated.accept(count: 100, reportedTotal: 20_000, fingerprint: "identical") }
        expect(repeated == before, "failed page cannot advance the cursor")
        fails("reject early empty page") { try repeated.accept(count: 0, reportedTotal: 20_000) }
        expect(repeated == before, "empty error preserves loaded range")
        fails("reject oversized response") { try repeated.accept(count: 101, reportedTotal: 20_000) }
        fails("negative total") { try repeated.accept(count: 1, reportedTotal: -1) }
        var limited = EmbyCursor()
        try limited.accept(count: 25, reportedTotal: 80, fingerprint: "short1")
        expect(limited.nextIndex == 25 && limited.hasMore, "server page below requested limit")
        try limited.accept(count: 25, reportedTotal: 80, fingerprint: "short2")
        expect(limited.nextIndex == 50, "offset uses actual rows")
        var unknown = EmbyCursor()
        try unknown.accept(count: 20, reportedTotal: nil)
        expect(unknown.hasMore, "no total does not truncate a short page")
        try unknown.accept(count: 0, reportedTotal: nil)
        expect(!unknown.hasMore && unknown.nextIndex == 20, "empty page terminates unknown total")
        var empty = EmbyCursor()
        try empty.accept(count: 0, reportedTotal: 0)
        expect(!empty.hasMore, "genuinely empty library")

        SecureVault.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TingFlowPaging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let makeClient: (URL, String) -> EmbyClient = { base, device in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [EmbyPagingFixture.self]
            return EmbyClient(base: base, device: device, configuration: config)
        }
        EmbyPagingFixture.configure(albumError: true)
        let store = EmbyStore(cacheDirectory: directory, clientFactory: makeClient)
        await store.signIn(baseURL: "https://example.invalid/proxy/emby", username: "fixture", password: "fixture")
        expect(store.isSignedIn, "metadata failure cannot undo successful login")
        expect(store.songs.count == 100, "first page publishes despite failed album list")
        expect(store.playlists.count == 1 && store.albums.isEmpty, "each type is independent")
        expect(store.pageState(.songs).cursor.total == 25_001 && store.pageState(.songs).cursor.hasMore, "large-library continuation")
        expect(store.pageState(.albums).error != nil && !store.isLoading, "failed type is retryable without permanent spinner")
        let initialCalls = EmbyPagingFixture.requests().filter { !$0.type.isEmpty }
        expect(initialCalls.count == 3, "initial refresh is three single-page requests, not full-library iteration")
        expect(initialCalls.allSatisfy { $0.offset == 0 && $0.limit == 100 && $0.hasCredential }, "page bound and scoped authentication")
        expect(initialCalls.allSatisfy { $0.path.hasPrefix("/proxy/emby/") }, "reverse-proxy prefix preserved")
        await store.loadMore(.songs)
        expect(store.songs.count == 200 && store.pageState(.songs).cursor.nextIndex == 200, "next page appends")
        expect(EmbyPagingFixture.requests().last?.offset == 100, "next query starts at 100")
        EmbyPagingFixture.configure(albumError: false, repeatAudioPage: true)
        await store.loadMore(.songs)
        expect(store.songs.count == 200 && store.pageState(.songs).cursor.nextIndex == 200, "repeat page retains last successful result")
        expect(store.pageState(.songs).error != nil, "paging fault identifies its own type")
        EmbyPagingFixture.configure(albumError: false)
        await store.loadMore(.songs)
        expect(store.songs.count == 300 && store.pageState(.songs).error == nil, "retry resumes without skipped offset")
        await store.loadMore(.albums)
        expect(store.albums.count == 1 && store.pageState(.albums).error == nil, "failed first page retries independently")
        expect(store.songs.count == 300 && store.playlists.count == 1, "album retry preserves other lists")
        EmbyPagingFixture.configure(albumError: true)
        await store.refresh()
        expect(store.albums.count == 1 && store.pageState(.albums).error != nil, "failed refresh retains complete cached albums")
        expect(store.pageState(.albums).retryFromStart, "refresh retry must start at zero rather than skip old range")
        EmbyPagingFixture.configure(albumError: false)
        await store.loadMore(.albums)
        expect(store.pageState(.albums).error == nil && store.albums.count == 1, "complete list can retry after refresh failure")
        expect(EmbyPagingFixture.requests().last?.offset == 0, "retry uses first-page offset")
        let result = try await store.search("fixture")
        expect(result.count == 100 && store.searchNotice?.contains("25") == true, "search is bounded and honestly labeled")
        let list = store.playlists[0]
        let first = try await store.tracks(in: list)
        let second = try await store.tracks(in: list, cursor: first.cursor)
        expect(first.songs.count == 100 && second.songs.count == 100 && second.cursor.nextIndex == 200, "playlist follows one-page cursor")
        expect(first.songs.allSatisfy { $0.platformID == "same-song" }, "playlist duplicate songs preserved")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let snapshot = try Data(contentsOf: files.first { $0.pathExtension == "json" }!)
        let snapshotText = String(decoding: snapshot, as: UTF8.self)
        expect(!snapshotText.contains("fixture-session-only") && snapshotText.contains("cursors"), "cache records ranges, never credentials")
        EmbyPagingFixture.configure(albumError: false, rejectAudio: true)
        await store.loadMore(.songs)
        expect(!store.isSignedIn && store.songs.isEmpty && store.libraryPages.isEmpty, "401 clears identity and all page states")
        expect(!store.isLoading, "auth expiry cancels loading flags")
        print("PASS: \(checks) Emby pagination and full-store fixture checks; no real accounts or network")
    }
}
