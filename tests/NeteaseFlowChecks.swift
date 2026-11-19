import Foundation

@main @MainActor struct NeteaseFlowChecks {
    static func main() async throws {
        var count = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, "FAIL: \(label)"); count += 1 }
        let make: () -> NeteaseClient = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NeteaseFlowFixture.self]
            return NeteaseClient(configuration: configuration, deviceID: String(repeating: "A", count: 52))
        }
        let client = make()
        let key = try await client.request(.qrKey, ["type": 3])
        expect(key["unikey"] != nil, "EAPI QR key path")
        let check = try await client.request(.qrCheck, ["key": "fixture", "type": 3])
        expect(check["code"] as? Int == 803, "QR success code not business rejection")
        let saved = try client.credentialData(userID: "7")
        SecureVault.values["netease.native.weapi.session.v1"] = saved
        let store = NeteaseStore(clientFactory: make)
        await store.refresh()
        expect(store.isSignedIn && store.scopeID == "netease:7", "canonical identity before library")
        expect(store.avatarURL?.absoluteString == "https://p1.music.126.net/fixture-avatar.jpg", "verified profile supplies unsigned HTTPS avatar")
        expect(store.playlists.count == 2, "my lists read")
        expect(store.createdPlaylists.count == 1 && store.createdPlaylists[0].isPrivate, "private created playlist classified")
        expect(store.subscribedPlaylists.count == 1, "subscribed lists independent")
        expect(store.dailySongs.count == 1 && store.dailySongs[0].duration == 1, "real daily song mapping")
        expect(store.dailyPlaylists.first?.id == "201" && store.personalizedPlaylists.first?.id == "301", "two recommendation response shapes")
        let tracks = try await store.tracks(in: store.createdPlaylists[0])
        expect(tracks.map(\.platformID) == ["2", "1", "2"], "private list preserves order and repeat IDs")
        expect(tracks.allSatisfy { $0.accountScope == "netease:7" }, "private tracks scoped to verified account")
        await store.loadPersonalFM()
        expect(store.fmSongs.first?.duration == 2 && store.fmSongs.first?.artist == "Singer", "FM legacy song fields")
        NeteaseFlowFixture.failDaily(true)
        await store.refresh()
        expect(store.isSignedIn && store.playlists.count == 2 && store.dailySongs.count == 1, "daily endpoint failure keeps login/library/success snapshot")
        expect(store.recommendationError?.contains("400") == true && store.recommendationError?.contains("private-secret") == false, "error code but no body leak")
        expect(!store.isLoading && !store.isLoadingRecommendations, "spinners finish after failure")
        let paths = NeteaseFlowFixture.requested()
        expect(paths.contains("/eapi/nuser/account/get") && !paths.contains("/eapi/w/nuser/account/get"), "identity path matches real client source")
        expect(paths.contains("/eapi/v3/discovery/recommend/songs") && paths.contains("/eapi/user/playlist"), "reviewed routes actually called")
        await store.signOut()
        expect(!store.isSignedIn && store.dailySongs.isEmpty && store.fmSongs.isEmpty && store.dailyPlaylists.isEmpty && store.personalizedPlaylists.isEmpty, "logout erases private recommendations")
        expect(SecureVault.values.isEmpty && store.playlists.isEmpty && store.avatarURL == nil, "logout removes vault, library and avatar")
        NeteaseFlowFixture.failDaily(false)
        print("PASS: \(count) Netease account/daily/private-list/FM fixture checks; no real login or SMS")
    }
}
