import Foundation
import Security

private final class NeteaseRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Candidate and authenticated sessions own separate ephemeral transports. Secrets only leave for the exact API URL.
@MainActor final class NeteaseClient {
    enum Endpoint: String {
        case qrKey = "/api/login/qrcode/unikey"
        case qrCheck = "/api/login/qrcode/client/login"
        case captchaSent = "/api/sms/captcha/sent"
        case phoneLogin = "/api/w/login/cellphone"
        case identity = "/api/nuser/account/get"
        case playlists = "/api/user/playlist"
        case playlist = "/api/v6/playlist/detail"
        case songs = "/api/v3/song/detail"
        case lyric = "/api/song/lyric"
        case playback = "/api/song/enhance/player/url"
        case playbackV1 = "/api/song/enhance/player/url/v1"
        case dailySongs = "/api/v3/discovery/recommend/songs"
        case dailyPlaylists = "/api/v1/discovery/recommend/resource"
        case personalizedPlaylists = "/api/personalized/playlist"
        case personalFM = "/api/v1/radio/get"
        case likedTracks = "/api/song/like/get"
        case likeTrack = "/api/radio/like"
        case subscribePlaylist = "/api/playlist/subscribe"
        case unsubscribePlaylist = "/api/playlist/unsubscribe"
        case manipulatePlaylistTracks = "/api/playlist/manipulate/tracks"
        case recentSongs = "/api/play-record/song/list"
        case playbackLog = "/api/feedback/weblog"
        var usesEAPI: Bool { !usesPlainWebAPI && self != .lyric && self != .playback }
        var usesPlainWebAPI: Bool { self == .captchaSent || self == .phoneLogin }
    }
    private struct Cookie: Codable { let name: String; let value: String; let expires: Date? }
    private struct Credential: Codable { let version: Int; let userID: String; let cookies: [Cookie] }
    private static let cookieNames: Set<String> = ["MUSIC_U", "MUSIC_A", "__csrf", "NMTID", "__remember_me", "WNMCID", "WEVNSM"]
    private let session: URLSession
    private let device: String
    private var cookies: [String: Cookie] = [:]
    private var invalidated = false
    private(set) var restoredUserID: String?
    private(set) var playbackDiagnostic: NeteasePlaybackDiagnostic?
    init(configuration: URLSessionConfiguration? = nil, deviceID: String? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: NeteaseRedirectBlocker(), delegateQueue: nil)
        device = deviceID ?? Self.installationID()
    }
    convenience init(credentialData: Data) throws {
        self.init()
        try restoreCredential(credentialData)
    }
    func restoreCredential(_ credentialData: Data) throws {
        guard !invalidated, cookies.isEmpty else { throw NeteaseError.storage }
        guard credentialData.count < 65536,
              let saved = try? JSONDecoder().decode(Credential.self, from: credentialData), saved.version == 1,
              let uid = NeteaseMapping.id(saved.userID) else { throw NeteaseError.storage }
        for item in saved.cookies where Self.valid(item) { cookies[item.name] = item }
        guard cookies["MUSIC_U"] != nil else { throw NeteaseError.signedOut }
        restoredUserID = uid
    }
    deinit { session.invalidateAndCancel() }
    func invalidate() { invalidated = true; cookies.removeAll(); restoredUserID = nil; playbackDiagnostic = nil; session.invalidateAndCancel() }
    private static func valid(_ cookie: Cookie) -> Bool {
        cookieNames.contains(cookie.name) && !cookie.value.isEmpty && cookie.value.utf8.count < 32768 &&
        cookie.value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e && ![34,44,59,92].contains($0) } &&
        (cookie.expires == nil || cookie.expires! > Date())
    }
    func credentialData(userID: String) throws -> Data {
        guard !invalidated, cookies["MUSIC_U"].map(Self.valid) == true else { throw NeteaseError.signedOut }
        return try JSONEncoder().encode(Credential(version: 1, userID: userID, cookies: cookies.values.filter(Self.valid)))
    }
    static func isAPIURL(_ url: URL) -> Bool { NeteaseWire.isAPIURL(url) }
    private static func installationID() -> String {
        let key = "tingflow.netease.eapi-device-id"
        if let stored = UserDefaults.standard.string(forKey: key), stored.count == 52, stored.allSatisfy(\.isHexDigit) { return stored }
        let alphabet = Array("0123456789ABCDEF")
        var bytes = [UInt8](repeating: 0, count: 52)
        let value: String
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess { value = String(bytes.map { alphabet[Int($0) % 16] }) }
        else { value = String((UUID().uuidString + UUID().uuidString).filter { $0 != "-" }.prefix(52)) }
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func request(_ endpoint: Endpoint, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        cookies = cookies.filter { Self.valid($0.value) }
        if endpoint == .playback || endpoint == .playbackV1 {
            playbackDiagnostic = NeteasePlaybackDiagnostic(v1: endpoint == .playbackV1, level: payload["level"] as? String)
        }
        let url = try NeteaseWire.url(endpoint)
        var jar = cookies.mapValues(\.value), fields = payload
        let body: Data
        if endpoint.usesPlainWebAPI {
            fields["csrf_token"] = jar["__csrf"] ?? ""
            let strings = fields.mapValues { String(describing: $0) }
            body = NeteaseCrypto.form(strings)
        } else if endpoint.usesEAPI {
            var header = NeteaseWire.header(device: device, csrf: jar["__csrf"] ?? "", cookies: jar)
            // Matches the audited scrobble route only; never overrides identity or credentials.
            if endpoint == .playbackLog { header["os"] = "osx" }
            fields["header"] = header; fields["e_r"] = false
            body = NeteaseCrypto.form(try NeteaseCrypto.sealEAPI(apiPath: endpoint.rawValue, object: fields))
            // The upstream EAPI contract sends the same allowlisted header as Cookie.
            // Do not add unrelated remembered browser cookies to authenticated API requests.
            jar = header
        } else {
            fields["csrf_token"] = jar["__csrf"] ?? ""; fields["e_r"] = false
            body = NeteaseCrypto.form(try NeteaseCrypto.seal(fields))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false; request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(endpoint == .playback || endpoint == .playbackV1 ? "https://music.163.com" : "https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(endpoint.usesEAPI ? "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)" :
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if !jar.isEmpty { request.setValue(jar.keys.sorted().map { "\($0)=\(jar[$0]!)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse, http.url == url else { throw NeteaseError.unsafeURL }
            if endpoint == .playback || endpoint == .playbackV1 { playbackDiagnostic?.httpStatus = http.statusCode }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { throw NeteaseError.signedOut }
                if http.statusCode == 429 { throw NeteaseError.rateLimited }
                throw NeteaseError.http(http.statusCode)
            }
            guard response.expectedContentLength <= 25_000_000 else { throw NeteaseError.response }
            var data = Data(); data.reserveCapacity(64_000)
            for try await byte in bytes {
                guard data.count < 25_000_000 else { throw NeteaseError.response }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["code"] as? Int else { throw NeteaseError.response }
            if endpoint == .playback || endpoint == .playbackV1 {
                playbackDiagnostic?.businessCode = code
                playbackDiagnostic?.mediaCodes = Array((object["data"] as? [[String: Any]] ?? []).prefix(8).compactMap { $0["code"] as? Int })
            }
            try NeteaseWire.validate(code: code, endpoint: endpoint)
            for parsed in NeteaseWire.responseCookies(http, url: url) {
                let domain = parsed.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard ["music.163.com", "interface.music.163.com"].contains(domain),
                      parsed.path == "/", Self.cookieNames.contains(parsed.name) else { continue }
                let value = Cookie(name: parsed.name, value: parsed.value, expires: parsed.expiresDate)
                if Self.valid(value) { cookies[value.name] = value } else { cookies.removeValue(forKey: value.name) }
            }
            return object
        } catch is CancellationError { throw CancellationError() }
        catch let error as NeteaseError { throw error }
        catch {
            if Task.isCancelled || invalidated { throw CancellationError() }
            if endpoint == .playbackV1, NeteaseAudioPolicy.isTransientTransport(error) { throw NeteaseError.transientNetwork }
            throw NeteaseError.network
        }
    }
}
