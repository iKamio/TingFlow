import Foundation
import CryptoKit
import Security
import ImageIO

struct SubsonicAlbum: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var artist: String? = nil
    let accountScope: String
    var coverArtID: String? = nil
    var songCount: Int? = nil
}
struct SubsonicPlaylist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var artist: String? = nil
    let accountScope: String
    var coverArtID: String? = nil
    var songCount: Int? = nil
}

enum SubsonicFailure: Error, LocalizedError, Equatable {
    case address, response, authentication, forbidden, incompatible, network, redirect, limit, artworkLimit, storage, account, signedOut
    var errorDescription: String? {
        switch self {
        case .address: return "请输入无凭据、查询、片段或路径跳转的最终 HTTPS 服务器根地址。"
        case .response: return "音乐服务器返回的数据无法识别。"
        case .authentication: return "音乐服务器身份验证失败，请重新登录；不回退到明文密码认证。"
        case .forbidden: return "音乐服务器拒绝访问，请检查账户权限。"
        case .incompatible: return "服务器不支持此版本的 Subsonic 令牌接口。"
        case .network: return "无法连接音乐服务器，请检查网络及 HTTPS 证书。"
        case .redirect: return "已拒绝服务器重定向，请填写最终 HTTPS API 根地址。"
        case .artworkLimit: return "音乐服务器原图超过 4,000,000 字节安全上限，未加载。"
        case .limit: return "本次响应超过 8 MiB 安全上限；请缩小服务器歌单或搜索范围。"
        case .storage: return "本机安全存储不可用，请解锁设备并检查空间后重试。"
        case .account: return "此内容不属于当前音乐服务器账户。"
        case .signedOut: return "请先连接 Navidrome 或 Subsonic 服务器。"
        }
    }
    static func safe(_ error: Error) -> SubsonicFailure { error as? SubsonicFailure ?? .network }
}

enum SubsonicPolicy {
    static let byteLimit = 8 * 1024 * 1024
    static let pageSize = 100
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    static func validArtworkID(_ value: String) -> Bool {
        validID(value) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("://")
    }
    static func artworkRevision(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func validUsername(_ value: String) -> Bool { validID(value) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    static func base(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, !text.contains("\\"),
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              var c = URLComponents(string: text), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.port == nil || (1...65535).contains(c.port!)
        else { throw SubsonicFailure.address }
        var parts: [String] = []
        let path = c.percentEncodedPath
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(part).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("%"),
                  !decoded.contains("/"), !decoded.contains("\\"),
                  decoded.rangeOfCharacter(from: .controlCharacters) == nil else { throw SubsonicFailure.address }
            if !decoded.isEmpty { parts.append(decoded) }
        }
        // Interior empty components can be interpreted differently by proxies.
        guard !path.contains("//") else { throw SubsonicFailure.address }
        c.scheme = "https"; c.host = host.lowercased(); if c.port == 443 { c.port = nil }
        c.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        guard let url = c.url else { throw SubsonicFailure.address }
        return url
    }
    static func endpoint(_ base: URL, _ method: String, query: [URLQueryItem] = []) throws -> URL {
        let allowed = ["ping", "getAlbumList2", "getPlaylists", "getAlbum", "getPlaylist", "search3", "stream", "getCoverArt"]
        guard allowed.contains(method), try self.base(base.absoluteString) == base,
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw SubsonicFailure.address }
        c.percentEncodedPath += "/rest/\(method).view"
        c.queryItems = query.isEmpty ? nil : query
        guard let result = c.url else { throw SubsonicFailure.address }
        return result
    }
    static func scope(base: URL, username: String) -> String {
        let data = Data((base.absoluteString + username).utf8)
        return "subsonic:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func salt() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SubsonicFailure.storage }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func form(_ items: [URLQueryItem]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(items.map { ($0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
    }
}

// Only this record enters Keychain. The original password is never retained.
struct SubsonicCredential: Codable {
    let server: URL
    let username: String
    let token: String
    let salt: String
    let navidrome: Bool
    var scope: String { SubsonicPolicy.scope(base: server, username: username) }
    var valid: Bool {
        (try? SubsonicPolicy.base(server.absoluteString)) == server && SubsonicPolicy.validUsername(username) &&
        token.count == 32 && salt.count == 32 && (token + salt).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    var parameters: [URLQueryItem] {
        [URLQueryItem(name: "u", value: username), URLQueryItem(name: "t", value: token),
         URLQueryItem(name: "s", value: salt), URLQueryItem(name: "v", value: "1.16.1"),
         URLQueryItem(name: "c", value: "TingFlow"), URLQueryItem(name: "f", value: "json")]
    }
}

struct SubsonicRecord: Decodable {
    let id: String
    let name: String?
    let title: String?
    let artist: String?
    let album: String?
    let albumId: String?
    let duration: Double?
    let coverArt: String?
    let isDir: Bool?
    let isVideo: Bool?
    let type: String?
    let songCount: Int?
    private enum CodingKeys: String, CodingKey {
        case id, name, title, artist, album, albumId, duration, coverArt, isDir, isVideo, type, songCount
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        coverArt = try? c.decode(String.self, forKey: .coverArt)
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        songCount = (try? c.decode(Int.self, forKey: .songCount)).flatMap { $0 >= 0 ? $0 : nil }
    }
    func song(scope: String) -> Song? {
        guard SubsonicPolicy.validID(id), isDir != true, isVideo != true, type != "video" else { return nil }
        let seconds = duration ?? 0
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Song(platform: .subsonic, platformID: id, title: title ?? name ?? "未知歌曲",
                    artist: artist ?? "未知艺术家", album: album ?? "未知专辑", duration: seconds,
                    artworkURL: nil, albumID: albumId.flatMap { SubsonicPolicy.validID($0) ? $0 : nil }, accountScope: scope)
    }
}
struct SubsonicResponse: Decodable {
    struct APIError: Decodable { let code: Int? } // Never decode or display the remote error message.
    struct Albums: Decodable { let album: [SubsonicRecord]? }
    struct Playlists: Decodable { let playlist: [SubsonicRecord]? }
    struct Album: Decodable { let id: String; let song: [SubsonicRecord]? }
    struct Playlist: Decodable { let id: String; let entry: [SubsonicRecord]? }
    struct Search: Decodable { let song: [SubsonicRecord]? }
    let status: String
    let error: APIError?
    let albumList2: Albums?
    let playlists: Playlists?
    let album: Album?
    let playlist: Playlist?
    let searchResult3: Search?
    static func decode(_ data: Data) throws -> Self {
        struct Envelope: Decodable {
            let response: SubsonicResponse
            enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
        }
        guard data.count <= SubsonicPolicy.byteLimit else { throw SubsonicFailure.limit }
        let response: SubsonicResponse
        do { response = try JSONDecoder().decode(Envelope.self, from: data).response }
        catch { throw SubsonicFailure.response }
        guard response.status == "ok", response.error == nil else {
            if response.status == "failed" {
                switch response.error?.code {
                case 40, 41, 42, 43, 44: throw SubsonicFailure.authentication
                case 50: throw SubsonicFailure.forbidden
                case 20, 30: throw SubsonicFailure.incompatible
                default: throw SubsonicFailure.response
                }
            }
            throw SubsonicFailure.response
        }
        return response
    }
}

private final class SubsonicNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil) // System TLS only; no trust exceptions.
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

final class SubsonicClient {
    let base: URL
    private let session: URLSession
    init(base: URL, configuration: URLSessionConfiguration? = nil) {
        self.base = base
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.urlCache = nil; config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: SubsonicNoRedirects(), delegateQueue: nil)
    }
    func cancel() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
    func request(_ method: String, credential: SubsonicCredential, parameters: [URLQueryItem] = []) async throws -> SubsonicResponse {
        do {
            try Task.checkCancellation()
            guard credential.valid, credential.server == base else { throw SubsonicFailure.account }
            let reserved: Set<String> = ["u", "t", "s", "v", "c", "f", "p"]
            guard !parameters.contains(where: { reserved.contains($0.name) }), method != "stream", method != "getCoverArt" else { throw SubsonicFailure.response }
            let url = try SubsonicPolicy.endpoint(base, method)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = SubsonicPolicy.form(credential.parameters + parameters)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, response.url == url else { throw SubsonicFailure.redirect }
            switch http.statusCode {
            case 200..<300: break
            case 300..<400: throw SubsonicFailure.redirect
            case 401: throw SubsonicFailure.authentication
            case 403: throw SubsonicFailure.forbidden
            default: throw SubsonicFailure.network
            }
            guard response.expectedContentLength <= Int64(SubsonicPolicy.byteLimit) else { throw SubsonicFailure.limit }
            var data = Data()
            for try await byte in bytes {
                guard data.count < SubsonicPolicy.byteLimit else { throw SubsonicFailure.limit }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try SubsonicResponse.decode(data)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw SubsonicFailure.safe(error)
        }
    }
    func artwork(id: String, credential: SubsonicCredential, pixels: Int = 320) async throws -> Data? {
        do {
            try Task.checkCancellation()
            guard credential.valid, credential.server == base, SubsonicPolicy.validArtworkID(id) else { throw SubsonicFailure.account }
            let url = try SubsonicPolicy.endpoint(base, "getCoverArt")
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.httpMethod = "POST"
            request.httpBody = SubsonicPolicy.form(credential.parameters + [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "size", value: pixels <= 320 ? "320" : "700")])
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(SubsonicArtworkBody.accept, forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, response.url == url else { throw SubsonicFailure.redirect }
            switch http.statusCode {
            case 200..<300: break
            case 404: return nil
            case 300..<400: throw SubsonicFailure.redirect
            case 401: throw SubsonicFailure.authentication
            case 403: throw SubsonicFailure.forbidden
            default: throw SubsonicFailure.network
            }
            guard let mime = response.mimeType?.lowercased(), SubsonicArtworkBody.types[mime] != nil else { throw SubsonicFailure.response }
            guard response.expectedContentLength <= Int64(SubsonicArtworkBody.byteLimit) else { throw SubsonicFailure.artworkLimit }
            var data = Data()
            for try await byte in bytes {
                guard data.count < SubsonicArtworkBody.byteLimit else { throw SubsonicFailure.artworkLimit }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard SubsonicArtworkBody.valid(data, mime: mime) else { throw SubsonicFailure.response }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw SubsonicFailure.safe(error) }
    }
    func playback(id: String, credential: SubsonicCredential) throws -> PlaybackResource {
        guard credential.valid, credential.server == base, SubsonicPolicy.validID(id) else { throw SubsonicFailure.account }
        // GET authentication is required by the standard. This URL must stay memory-only.
        let url = try SubsonicPolicy.endpoint(base, "stream", query: credential.parameters + [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "format", value: "raw")])
        return PlaybackResource(url: url, displayQuality: credential.navidrome ? "Navidrome · 原始音频" : "Subsonic · 原始音频", requiresResourceLoader: true)
    }
}

private enum SubsonicArtworkBody {
    static let byteLimit = 4_000_000
    static let types: [String: Set<String>] = [
        "image/jpeg": ["public.jpeg"], "image/png": ["public.png"],
        "image/webp": ["org.webmproject.webp"], "image/gif": ["com.compuserve.gif"],
        "image/heic": ["public.heic", "public.heif"], "image/heif": ["public.heif", "public.heic"]
    ]
    static let accept = "image/jpeg, image/png, image/webp, image/heic, image/heif, image/gif"
    static func valid(_ data: Data, mime: String) -> Bool {
        guard !data.isEmpty, data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), types[mime]?.contains(type as String) == true,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
        else { return false }
        let w = width.int64Value, h = height.int64Value
        return (1...16_384).contains(w) && (1...16_384).contains(h) && w * h <= 80_000_000
    }
}
