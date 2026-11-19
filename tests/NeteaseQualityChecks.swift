import Foundation

// Link NeteaseFlowFixture.swift for its in-memory SecureVault, never the production vault.
@main @MainActor struct NeteaseQualityChecks {
    static func main() async throws {
        var count = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, "FAIL: \(label)"); count += 1 }
        let make: @MainActor () -> NeteaseClient = {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [NeteaseQualityFixture.self]
            return NeteaseClient(configuration: config, deviceID: String(repeating: "A", count: 52))
        }
        SecureVault.values["netease.native.weapi.session.v1"] = try JSONSerialization.data(withJSONObject: [
            "version": 1, "userID": "7", "cookies": [["name": "MUSIC_U", "value": "synthetic-quality-fixture"]]])
        let store = NeteaseStore(clientFactory: make)
        NeteaseQualityFixture.configure([])
        await store.refresh()
        expect(store.isSignedIn && store.avatarURL?.absoluteString == "https://p1.music.126.net/fixture-avatar.jpg", "verified refresh avatar upgraded safely")
        let song = Song(platform: .netease, platformID: "1", title: "Fixture", artist: "", album: "", duration: 1, accountScope: "netease:7")
        let row: [String: Any] = ["id": 1, "code": 200, "url": "https://m1.music.126.net/fixture.mp3?signature=synthetic", "type": "mp3", "br": 128000, "level": "standard", "freeTrialInfo": NSNull(), "fee": 1, "pl": 128000]
        let original = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        for quality in AudioQuality.allCases {
            NeteaseQualityFixture.configure([.row(row)])
            let resource = try await store.playback(for: song, quality: quality)
            let requests = NeteaseQualityFixture.requests()
            expect(requests.count == 1 && requests[0].0 == "/eapi/song/enhance/player/url/v1", "one native EAPI route")
            let payload = requests[0].1
            expect(payload["ids"] as? String == "[1]" && payload["level"] as? String == NeteaseAudioPolicy.level(for: quality) && payload["encodeType"] as? String == "flac", "encrypted wire quality/ids/encoding")
            expect(payload["br"] == nil && payload["unblock"] == nil && payload["header"] != nil, "no legacy br or unblock in v1")
            expect(resource.displayQuality.contains("128 kbps") && !resource.displayQuality.contains("FLAC") && resource.headers.isEmpty, "server downgrade honest and audio has no account headers")
        }
        NeteaseQualityFixture.configure([.row(row)])
        _ = try await store.playback(for: song)
        expect(NeteaseQualityFixture.requests()[0].1["level"] as? String == "exhigh", "old call signature defaults to high")
        NeteaseQualityFixture.configure([], legacy: [.row(row)])
        let standard = try await store.playback(for: song, quality: .lossless, mode: .legacyStandard)
        expect(NeteaseQualityFixture.requests().map { $0.0 } == ["/weapi/song/enhance/player/url"], "explicit standard mode sends one known legacy request")
        expect(standard.displayQuality.contains("128 kbps") && standard.neteaseHistoryScope == "netease:7", "legacy actual quality and verified original scope")
        var drm = row; drm["isDRM"] = true
        var denied = row; denied["url"] = NSNull()
        var trial = row; trial["freeTrialInfo"] = ["start": 0, "end": 30]
        var rowRisk = row; rowRisk["code"] = -462
        let blocked: [NeteaseQualityFixture.Reply] = [.http(404), .http(503), .transport(.networkConnectionLost), .business(301), .business(-460), .business(403), .business(429), .http(403), .http(429), .row(rowRisk), .row(drm), .row(denied), .transport(.serverCertificateUntrusted)]
        for failure in blocked {
            NeteaseQualityFixture.configure([failure], legacy: [.row(row)])
            do { _ = try await store.playback(for: song, quality: .lossless); preconditionFailure("denied playback succeeded") } catch { }
            expect(NeteaseQualityFixture.requests().count == 1, "no fallback for rights/auth/verification/rate/TLS")
        }
        NeteaseQualityFixture.configure([.business(-460)], legacy: [.row(row)])
        do { _ = try await store.playback(for: song, quality: .lossless); preconditionFailure("risk accepted") }
        catch { expect(error as? NeteaseError == .playbackVerification(-460), "observed real failure keeps exact safe number") }
        expect(NeteaseQualityFixture.requests().count == 1 && store.isSignedIn, "verification never retries, changes identity or automatically downgrades")
        expect(!NeteasePlaybackSafety.allowsSourceFallback(after: NeteaseError.playbackVerification(-460)), "observed denial cannot trigger source chain")
        NeteaseQualityFixture.configure([.business(-462)])
        do { _ = try await store.playback(for: song); preconditionFailure("risk accepted") } catch { }
        expect(store.playbackDiagnostic?.contains("-462") == true && store.playbackDiagnostic?.contains("HTTP：200") == true, "diagnostic retains exact safe status")
        expect(store.playbackDiagnostic?.contains("synthetic-quality-fixture") == false && store.playbackDiagnostic?.contains("signature=") == false, "no credentials in diagnostic")
        expect(!NeteasePlaybackSafety.allowsSourceFallback(after: NeteaseError.verification) && !NeteasePlaybackSafety.allowsSourceFallback(after: NeteaseError.drmRestricted), "security and DRM never start source chain")
        expect(NeteasePlaybackSafety.allowsSourceFallback(after: NeteaseError.unavailable), "only no-content result allows source consideration")
        var mixed = row; mixed["level"] = "lossless"
        let mapped = try NeteaseMapping.playback(["data": [mixed]], songID: "1")
        expect(mapped.displayQuality.contains("128 kbps") && !mapped.displayQuality.contains("FLAC"), "level alone never claims FLAC")
        mixed["type"] = "flac"; mixed["br"] = 900000
        let flac = try NeteaseMapping.playback(["data": [mixed]], songID: "1")
        expect(flac.mimeType == "audio/flac" && flac.displayQuality.contains("FLAC") && flac.displayQuality.contains("900 kbps"), "actual returned FLAC codec and bitrate")
        let preview = try NeteaseMapping.playback(["data": [trial]], songID: "1")
        expect(preview.isPreview && preview.displayQuality.contains("平台试听"), "trial stays trial")
        expect(try JSONSerialization.data(withJSONObject: row, options: .sortedKeys) == original, "mapping never changes fee or pl")
        for unsafe in ["https://m1.music.126.net/audio.mp3", "https://p1.music.126.net/x?token=secret", "https://p1.music.126.net/x#secret", "https://p1.music.126.net.evil.invalid/x", "https://u:p@p1.music.126.net/x", "https://p1.music.126.net:444/x"] {
            expect(NeteaseMapping.artworkURL(unsafe) == nil, "avatar static-host/unsigned origin policy")
        }
        NeteaseQualityFixture.configure([], avatarURL: "https://p1.music.126.net/x?token=secret")
        await store.refresh()
        expect(store.isSignedIn && store.avatarURL == nil, "invalid refreshed avatar clears stale image, not identity")
        await store.signOut()
        expect(store.avatarURL == nil && SecureVault.values.isEmpty, "logout clears avatar and fixture credentials")
        print("PASS: \(count) Netease quality/avatar fixture checks; no real account or audio requests")
    }
}
