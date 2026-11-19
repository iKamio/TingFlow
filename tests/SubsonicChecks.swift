// Offline Subsonic policy and synthetic wire-fixture checks.
// Build with the app's Models.swift, PlaybackResource.swift and SubsonicClient.swift.
import Foundation

@main struct SubsonicChecks {
    static func main() throws {
        var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), "FAIL: \(label)"); count += 1
        }
        func rejects(_ expected: SubsonicFailure, _ label: String, _ work: () throws -> Void) {
            do { try work(); preconditionFailure("FAIL: \(label)") }
            catch { expect(error as? SubsonicFailure == expected, label) }
        }

        expect(SubsonicPolicy.token(password: "sesame", salt: "c19b2d") ==
               "26719a1196d2a940705a59634eb18eab", "official MD5 token vector")
        expect(SubsonicPolicy.pageSize == 100 && SubsonicPolicy.byteLimit == 8 * 1024 * 1024,
               "bounded library and response windows")
        let base = try SubsonicPolicy.base("https://music.example.invalid/music/")
        expect(base.absoluteString == "https://music.example.invalid/music", "preserve reverse-proxy path")
        for raw in [
            "http://music.example.invalid", "https://u:p@music.example.invalid/music",
            "https://music.example.invalid/music?x=1", "https://music.example.invalid/music#x",
            "https://music.example.invalid/music/../private", "https://music.example.invalid/music/%2e%2e/private",
            "https://music.example.invalid/music//rest"
        ] {
            rejects(.address, "reject unsafe server address") { _ = try SubsonicPolicy.base(raw) }
        }
        let stream = try SubsonicPolicy.endpoint(base, "stream", query: [
            URLQueryItem(name: "id", value: "opaque/id?1"), URLQueryItem(name: "format", value: "raw")])
        let decodedQuery = URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems
        expect(stream.path == "/music/rest/stream.view" && decodedQuery?.first(where: { $0.name == "id" })?.value == "opaque/id?1",
               "round-trip opaque stream ID under reverse-proxy path")
        let form = String(decoding: SubsonicPolicy.form([
            URLQueryItem(name: "u", value: "a b"), URLQueryItem(name: "t", value: "a+b/c")]), as: UTF8.self)
        expect(form == "u=a%20b&t=a%2Bb%2Fc", "POST form encoding")

        let fixture = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"opaque/id","name":"Fixture Album","artist":"Fixture Artist","coverArt":"cover-id"}]},"playlist":{"id":"pl","entry":[{"id":"same","title":"One","album":"A","artist":"X","duration":42},{"id":"same","title":"One again","album":"A","artist":"X","duration":43}]}}}
        """.data(using: .utf8)!
        let decoded = try SubsonicResponse.decode(fixture)
        let album = decoded.albumList2?.album?.first
        expect(album?.id == "opaque/id" && album?.coverArt == "cover-id", "decode album opaque IDs and cover ID")
        let songs = decoded.playlist?.entry?.compactMap { $0.song(scope: "subsonic:fixture") } ?? []
        expect(songs.count == 2 && songs[0].platformID == songs[1].platformID && songs[0].duration == 42,
               "preserve playlist duplicate entries and seconds")
        expect(songs.allSatisfy { $0.artworkURL == nil && $0.accountScope == "subsonic:fixture" },
               "never turn cover art into an authenticated URL")
        let bad = Data(#"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"password-secret"}}}"#.utf8)
        do { _ = try SubsonicResponse.decode(bad); preconditionFailure("FAIL: failed response") }
        catch {
            expect(error as? SubsonicFailure == .authentication, "map standard authentication error")
            expect((error as? SubsonicFailure)?.localizedDescription.contains("password-secret") == false,
                   "redact server error message")
        }

        let salt = "c19b2d" + String(repeating: "0", count: 26)
        let credential = SubsonicCredential(server: base, username: "alice",
            token: SubsonicPolicy.token(password: "sesame", salt: salt), salt: salt, navidrome: true)
        expect(credential.valid && credential.parameters.contains(where: { $0.name == "f" && $0.value == "json" }),
               "validated token credential uses JSON API")
        let credentialData = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        expect(!credentialData.contains("password") && !credentialData.contains("p="),
               "keychain record contains no plaintext password or legacy p auth")
        let resource = try SubsonicClient(base: base).playback(id: "opaque/id?1", credential: credential)
        expect(resource.headers.isEmpty && resource.requiresResourceLoader && resource.url.query?.contains("t=") == true,
               "memory-only authenticated stream resource")
        expect(resource.url.query?.contains("format=raw") == true && resource.url.path.hasSuffix("/rest/stream.view"),
               "request raw stream without transcode")
        print("PASS: \(count) Subsonic offline checks")
    }
}
