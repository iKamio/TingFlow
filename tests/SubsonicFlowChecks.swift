import Foundation

@main @MainActor struct SubsonicFlowChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubsonicFlow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubsonicStore(cacheDirectory: root, clientFactory: { base in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SubsonicFlowFixture.self]
            return SubsonicClient(base: base, configuration: config)
        })
        await store.signIn(baseURL: "https://music.example.invalid/music", username: "fixture", password: "fixture-value", navidrome: true)
        check(store.isSignedIn && store.serviceLabel == "Navidrome" && store.errorMessage == nil, "ping activates validated account")
        check(store.albums.count == 100 && store.playlists.count == 1, "bounded first library page")
        await store.loadMoreAlbums()
        check(store.albums.count == 102 && !store.isLoading && store.errorMessage == nil, "album continuation offset")
        let album = try await store.tracks(in: store.albums[0])
        check(album.count == 2 && album[0].duration == 123, "actual album response mapped in seconds")
        let playlist = try await store.tracks(in: store.playlists[0])
        check(playlist.map(\.platformID) == ["b", "a", "b"], "duplicate playlist entries stay ordered")
        let results = try await store.search("fixture")
        check(results.count == 1 && results[0].accountScope == store.scopeID, "server search isolated")
        let resource = try await store.playback(for: results[0])
        check(resource.requiresResourceLoader && resource.url.path == "/music/rest/stream.view", "public authenticated loader under exact server prefix")
        let params = URLComponents(url: resource.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(params.first(where: { $0.name == "id" })?.value == "opaque/id?1", "opaque ID safe round-trip")
        check(resource.headers.isEmpty && params.first(where: { $0.name == "p" }) == nil, "no plaintext password in stream")
        check(SubsonicFlowFixture.requestsAreSafe, "API credentials only in same-origin POST body")
        let data = try JSONEncoder().encode(results)
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains("t=") && !text.contains("synthetic-not-a-real-password") && results[0].artworkURL == nil, "metadata has no authenticated URLs")
        await store.signOut()
        check(!store.isSignedIn && store.scopeID == nil && store.albums.isEmpty && store.songs.isEmpty && SecureVault.values.isEmpty, "logout drops credential and private data")
        do { _ = try await store.playback(for: results[0]); preconditionFailure("old song accepted after logout") }
        catch { check(error as? SubsonicFailure == .signedOut, "old server songs rejected after logout") }
        print("PASS: \(count) Navidrome/Subsonic actual-store protocol fixtures; no server accounts")
    }
}
