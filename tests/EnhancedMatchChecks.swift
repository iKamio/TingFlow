import Foundation

private final class EnhancedMatchFixture: URLProtocol {
    static var body = Data()
    static var status = 200
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Content-Length": String(Self.body.count),
                                                      "Set-Cookie": "fixture-cookie=never-forward; Secure"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct EnhancedMatchChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    static func body(_ direct: Any, proxy: String = "", code: Int = 200) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": code, "data": direct, "proxyUrl": proxy])
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(label) } catch { count += 1 }
    }
    static func main() async throws {
        var config = EnhancedMatchConfiguration()
        check(!config.enabled && config.address.isEmpty && config.source == .automatic, "matching is opt-in and has no built-in service")
        config.address = " https://api.example.invalid/netease/ "
        let automatic = try config.requestURL(songID: "123")
        let automaticParts = URLComponents(url: automatic, resolvingAgainstBaseURL: false)!
        check(automaticParts.path == "/netease/song/url/match", "base path is retained")
        let query = Dictionary(uniqueKeysWithValues: automaticParts.queryItems!.map { ($0.name, $0.value!) })
        check(query == ["id": "123", "noCookie": "true"], "minimal anonymous match request, no pretend quality flag")
        config.source = .unm
        check(try config.requestURL(songID: "123").query?.contains("source=unm") == true, "selected tool module reaches server")
        for address in ["http://api.example.invalid", "https://u:p@api.example.invalid", "https://api.example.invalid?token=secret", "https://api.example.invalid#fragment", "https://api.example.invalid:8443", "https://127.0.0.1", "https://localhost"] {
            var unsafe = config; unsafe.address = address
            rejects("unsafe configuration accepted") { _ = try unsafe.baseURL() }
        }
        for id in ["", "0", "01", "1&cookie=x", "-1", "18446744073709551616"] {
            rejects("invalid track ID accepted") { _ = try config.requestURL(songID: id) }
        }
        let result = try EnhancedMatchClient.resource(body("https://audio.example.invalid/track.flac?sig=fixture"), source: .unm)
        check(result.url.host == "audio.example.invalid" && result.headers.isEmpty && result.neteaseHistoryScope == nil,
              "no account credentials or native history attribution")
        check(result.requiresResourceLoader && result.mimeType == nil && !result.displayQuality.contains("FLAC"),
              "bounded no-redirect range loader and honest unverified quality")
        let proxy = try EnhancedMatchClient.resource(body("http://audio.example.invalid/track.mp3", proxy: "https://proxy.example.invalid/audio/123"), source: .automatic)
        check(proxy.url.host == "proxy.example.invalid", "HTTPS proxy accepted when direct URL is cleartext")
        let preferredProxy = try EnhancedMatchClient.resource(body("https://audio.example.invalid/redirect", proxy: "https://proxy.example.invalid/audio/123"), source: .automatic)
        check(preferredProxy.url.host == "proxy.example.invalid", "server HTTPS proxy takes precedence over potentially redirecting direct audio")
        let filteredProxy = try EnhancedMatchClient.resource(body("https://audio.example.invalid/audio.mp3", proxy: "https://proxy.example.invalid/playlist.m3u8"), source: .automatic)
        check(filteredProxy.url.host == "audio.example.invalid", "unsupported proxy format does not hide valid direct audio")
        for address in ["http://audio.example.invalid/track.mp3", "https://127.0.0.1/a", "https://u:p@audio.example.invalid/a", "https://audio.example.invalid/a.m3u8"] {
            rejects("unsafe audio accepted") { _ = try EnhancedMatchClient.resource(body(address), source: .automatic) }
        }
        rejects("array response accepted as an audio URL") { _ = try EnhancedMatchClient.resource(body([]), source: .automatic) }
        rejects("unavailable response accepted") { _ = try EnhancedMatchClient.resource(body("https://audio.example.invalid/a", code: 500), source: .automatic) }
        rejects("oversized response accepted") { _ = try EnhancedMatchClient.resource(Data(repeating: 32, count: 64_001), source: .automatic) }

        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [EnhancedMatchFixture.self]
        let client = EnhancedMatchClient(configuration: transport)
        let song = Song(platform: .netease, platformID: "123", title: "Synthetic", artist: "Fixture", album: "", duration: 120)
        config.enabled = true
        EnhancedMatchFixture.body = try body("https://audio.example.invalid/a.mp3")
        _ = try await client.playback(for: song, configuration: config)
        _ = try await client.playback(for: song, configuration: config)
        check(EnhancedMatchFixture.requests.count == 2, "signed audio links not cached between requests")
        for request in EnhancedMatchFixture.requests {
            check(request.httpMethod == "GET" && !request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil &&
                  request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Referer") == nil,
                  "anonymous transport does not retain server cookies or platform credentials")
        }

        let full = PlaybackResource(url: URL(string: "https://native.example.invalid/full.mp3")!)
        var preview = full; preview.isPreview = true
        let matched = PlaybackResource(url: URL(string: "https://match.example.invalid/audio")!)
        var nativeCalls = 0, sourceCalls = 0, matchCalls = 0
        let native: () async throws -> PlaybackResource = { nativeCalls += 1; return full }
        let source: () async throws -> PlaybackResource = { sourceCalls += 1; throw MusicError.noSource }
        let match: () async throws -> PlaybackResource = { matchCalls += 1; return matched }
        let original = try await NeteasePlaybackResolver.resolve(native: native, prefersUserSource: false, userSource: source, match: match)
        check(original.url == full.url && nativeCalls == 1 && sourceCalls == 0 && matchCalls == 0, "native complete audio wins")
        let failures: [Error] = [NeteaseError.signedOut, NeteaseError.playbackVerification(-460), NeteaseError.rateLimited,
                                 NeteaseError.drmRestricted, URLError(.serverCertificateUntrusted), CancellationError()]
        for failure in failures {
            do {
                _ = try await NeteasePlaybackResolver.resolve(native: { throw failure }, prefersUserSource: false, userSource: source, match: match)
                preconditionFailure("unsafe native error triggered fallback")
            } catch {}
        }
        check(sourceCalls == 0 && matchCalls == 0, "security and cancellation failures never trigger third-party requests")
        let fallback = try await NeteasePlaybackResolver.resolve(native: { throw NeteaseError.unavailable }, prefersUserSource: false, userSource: source, match: match)
        check(fallback.url == matched.url && sourceCalls == 1 && matchCalls == 1, "no-content tries enabled scripts before matching")
        do {
            _ = try await NeteasePlaybackResolver.resolve(native: native, prefersUserSource: true, userSource: source, match: match)
            preconditionFailure("manual selection silently changed")
        } catch {}
        check(matchCalls == 1, "manual parser failure does not silently choose a different service")
        for terminal in [SourceFailure.cancelled, .busy] {
            for isPreview in [false, true] {
                do {
                    _ = try await NeteasePlaybackResolver.resolve(native: {
                        if isPreview { return preview }
                        throw NeteaseError.unavailable
                    }, prefersUserSource: false, userSource: { throw terminal }, match: match)
                    preconditionFailure("terminal script state swallowed")
                } catch {
                    if terminal == .cancelled { check(error is CancellationError, "script cancellation normalized") }
                    else { check((error as? SourceFailure) == .busy, "busy source terminates request") }
                }
            }
        }
        check(matchCalls == 1, "script cancellation and busy never start matching or restore preview")
        let retained = try await NeteasePlaybackResolver.resolve(native: { preview }, prefersUserSource: false, userSource: nil, match: { throw EnhancedMatchFailure.unavailable })
        check(retained.isPreview && retained.url == preview.url, "preview survives failed optional matching")
        let replacement = try await NeteasePlaybackResolver.resolve(native: { preview }, prefersUserSource: false, userSource: nil, match: match)
        check(replacement.url == matched.url, "preview can be replaced by opted-in match")
        print("PASS: \(count) synthetic match configuration, response, transport and playback fallback checks; no real audio/account requests")
    }
}
