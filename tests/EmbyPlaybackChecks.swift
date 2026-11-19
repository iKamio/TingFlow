// macOS compile with Models, PlaybackResource, EmbyClient, EmbyPaging,
// EmbyPlaybackDiagnostic, EmbyStore and EmbyPagingFixture (not its @main checks).
import Foundation

@main struct EmbyPlaybackChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, "FAIL: \(label)"); checks += 1 }
        func source(_ fields: [String: Any]) throws -> EmbySource {
            try JSONDecoder().decode(EmbySource.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        func fields(_ container: String = "m4a", _ codec: String = "aac") -> [String: Any] {
            ["Id": "source-a", "Protocol": "Http", "Container": container,
             "MediaStreams": [["Type": "Audio", "Codec": codec]],
             "Path": "https://outside.invalid/private?api_key=DO-NOT-EXPORT",
             "DirectStreamUrl": "https://outside.invalid/direct", "TranscodingUrl": "/hidden.m3u8"]
        }
        let base = try EmbyAddress.base("https://example.invalid/proxy/emby")
        let remote = try source(fields())
        expect(remote.progressiveMIME == "audio/mp4", "HTTP and omitted capability flags permit verified audio")
        for (container, codec, mime) in [("mp3", "mp3", "audio/mpeg"), ("aac", "aac", "audio/aac"),
                                       ("m4a", "alac", "audio/mp4"), ("flac", "flac", "audio/flac"),
                                       ("wav", "pcm_s24le", "audio/wav")] {
            expect(try source(fields(container, codec)).progressiveMIME == mime, "matching native codec \(codec)")
        }
        for (container, codec) in [("wav", "aac"), ("m4a", "unknown"), ("flac", "mp3"), ("mp3", "alac")] {
            expect(try source(fields(container, codec)).progressiveMIME == nil, "reject mismatched or unknown codec")
        }
        var denied = fields(); denied["SupportsDirectPlay"] = false; denied["SupportsDirectStream"] = false
        expect(try source(denied).progressiveMIME == nil, "both explicit false honored")
        denied["SupportsDirectStream"] = true
        expect(try source(denied).progressiveMIME != nil, "one actual supported route sufficient")
        for key in ["RequiresOpening", "RequiresClosing", "IsInfiniteStream", "RequiresLooping"] {
            var live = fields(); live[key] = true
            expect(try source(live).progressiveMIME == nil, "no unsupported live lifecycle \(key)")
        }
        var video = fields(); video["MediaStreams"] = [["Type": "Audio", "Codec": "aac"], ["Type": "Video", "Codec": "h264"]]
        expect(try source(video).progressiveMIME == nil, "audio-only validation")
        let resource = try EmbyPlaybackPolicy.resource(base: base, item: "song-0", source: remote, token: "fixture-only")
        expect(resource.url.host == base.host && resource.url.path == "/proxy/emby/Audio/song-0/stream.m4a", "exact same-origin prefixed static route")
        let query = URLComponents(url: resource.url, resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.contains(URLQueryItem(name: "static", value: "true")) && query.contains(URLQueryItem(name: "MediaSourceId", value: "source-a")), "selected source and static true")
        expect(resource.headers == ["X-Emby-Token": "fixture-only"] && resource.requiresResourceLoader, "header-only authenticated range loader")
        expect(!resource.url.absoluteString.contains("api_key") && !resource.url.absoluteString.contains("fixture-only"), "no URL credentials")
        for (wire, expected) in [("\"NotAllowed\"", EmbyFailure.forbidden), ("\"NoCompatibleStream\"", .noCompatibleStream),
                                 ("\"RateLimitExceeded\"", .rateLimited), ("0", .playbackError), ("\"new-code\"", .playbackError), ("\"\"", .playbackError)] {
            let info = try JSONDecoder().decode(EmbyInfo.self, from: Data("{\"ErrorCode\":\(wire)}".utf8))
            expect(info.ErrorCode?.failure.localizedDescription == expected.localizedDescription, "exact error \(wire)")
        }
        let safe = EmbyPlaybackDiagnostic.make(try JSONSerialization.data(withJSONObject: ["MediaSources": [fields()]]))
        expect(safe.contains("TranscodingUrl存在：true") && safe.contains("SupportsTranscoding"), "URL presence and transcode support only")
        expect(!safe.contains("outside.invalid") && !safe.contains("DO-NOT-EXPORT") && !safe.contains("source-a") && !safe.contains("hidden.m3u8"), "diagnostic secrets allowlist")

        SecureVault.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TingFlowPlayback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbyStore(cacheDirectory: directory) { base, device in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EmbyPagingFixture.self]
            return EmbyClient(base: base, device: device, configuration: config)
        }
        EmbyPagingFixture.configure(albumError: false)
        await store.signIn(baseURL: base.absoluteString, username: "fixture", password: "fixture")
        expect(store.isSignedIn && store.songs.count == 100, "actual store keeps bounded first page")
        let song = store.songs[0]
        EmbyPagingFixture.setPlayback(["MediaSources": [fields()]])
        let beforePlayback = EmbyPagingFixture.requests().count
        let actual = try await store.playback(for: song)
        let call = EmbyPagingFixture.requests().last!
        let body = call.body!, profile = body["DeviceProfile"] as! [String: Any]
        expect(call.path == "/proxy/emby/Items/song-0/PlaybackInfo" && call.hasCredential, "store negotiates exact item with token")
        expect(EmbyPagingFixture.requests().count == beforePlayback + 1, "known audio needs no detail lookup")
        expect(body["MaxStreamingBitrate"] as? Int == EmbyPlaybackPolicy.maxBitrate && profile["MaxStreamingBitrate"] as? Int == EmbyPlaybackPolicy.maxBitrate && profile["MaxStaticMusicBitrate"] as? Int == EmbyPlaybackPolicy.maxBitrate, "actual wire request has explicit nonzero caps")
        expect(body["EnableTranscoding"] as? Bool == false && body["AutoOpenLiveStream"] as? Bool == false && (profile["TranscodingProfiles"] as? [Any])?.isEmpty == true, "no unusable HLS or live auto-open requested")
        let direct = profile["DirectPlayProfiles"] as! [[String: String]]
        expect(direct.contains { $0["AudioCodec"]?.contains("alac") == true } && direct.contains { $0["AudioCodec"]?.contains("pcm_s24le") == true }, "advertise ALAC and matching WAV PCM")
        expect(actual.url == resource.url && actual.headers["X-Emby-Token"] == "fixture-session-only", "actual store returns safe static URL and header")

        var incomplete = fields(); incomplete.removeValue(forKey: "MediaStreams")
        let detail: [String: Any] = ["Id": "song-0", "Type": "Audio", "MediaSources": [fields()]]
        EmbyPagingFixture.setPlayback(["MediaSources": [incomplete]], detail: detail)
        let beforeDetail = EmbyPagingFixture.requests().count
        let supplemented = try await store.playback(for: song)
        expect(supplemented.url == actual.url && EmbyPagingFixture.requests().count == beforeDetail + 2, "one bounded same-item codec fallback")
        expect(EmbyPagingFixture.requests().last?.path == "/proxy/emby/Users/fixture-user/Items/song-0", "fallback remains same-account same-origin")
        expect(store.playbackDiagnostic?.contains("AudioCodec：aac") == true, "fallback diagnostic includes only sanitized codec")

        let cases: [([String: Any], EmbyFailure)] = [
            (["ErrorCode": "NotAllowed"], .forbidden), (["ErrorCode": "RateLimitExceeded"], .rateLimited),
            (["ErrorCode": "NoCompatibleStream"], .noCompatibleStream), (["ErrorCode": 0], .playbackError),
            (["ErrorCode": "unknown"], .playbackError), ([:], .missingSources), (["MediaSources": []], .emptySources),
            (["MediaSources": [fields("m4a", "unknown")]], .unverifiedAudio)]
        for (response, expected) in cases {
            EmbyPagingFixture.setPlayback(response)
            let beforeError = EmbyPagingFixture.requests().count
            do { _ = try await store.playback(for: song); preconditionFailure("expected playback rejection") }
            catch { expect((error as? EmbyFailure)?.localizedDescription == expected.localizedDescription, "store preserves exact error") }
            expect(EmbyPagingFixture.requests().count == beforeError + 1, "bounded failure without retry/bypass")
        }
        EmbyPagingFixture.setPlayback(["MediaSources": [incomplete]], detail: ["Id": "another-song", "Type": "Audio", "MediaStreams": [["Type": "Audio", "Codec": "aac"]]])
        do { _ = try await store.playback(for: song); preconditionFailure("different item metadata accepted") }
        catch { expect((error as? EmbyFailure)?.localizedDescription == EmbyFailure.response.localizedDescription, "fallback verifies exact item ID") }
        await store.signOut()
        expect(!store.isSignedIn && store.playbackDiagnostic == nil, "logout clears diagnostics and account")
        print("PASS: \(checks) Emby playback policy and actual-store fixture checks; no real server/accounts")
    }
}
