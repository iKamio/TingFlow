import Foundation
import CryptoKit

struct EmbyAlbum: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let accountScope: String
    var title: String { name }
}

struct EmbyPlaylist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let accountScope: String
    var title: String { name }
}

enum EmbyFailure: LocalizedError {
    case address, response, unauthorized, forbidden, http(Int), network, redirect
    case signedOut, account, unsupported, limit, paging, storage, remoteLogout
    case rateLimited, noCompatibleStream, missingSources, emptySources, playbackError
    case unverifiedAudio, liveStream, transcodingRequired
    var errorDescription: String? {
        switch self {
        case .address: return "请输入无凭据、查询或片段的 HTTPS Emby 根地址。"
        case .response: return "Emby 返回的数据不完整或无法识别。"
        case .unauthorized: return "Emby 身份验证失败，请重新登录。"
        case .forbidden: return "Emby 拒绝访问，请检查账户权限。"
        case .http(let code): return "Emby 请求失败（HTTP \(code)）。"
        case .network: return "无法连接 Emby，请检查网络及服务器证书。"
        case .redirect: return "已拒绝 Emby 重定向，请填写最终 HTTPS API 根地址。"
        case .signedOut: return "请先登录 Emby。"
        case .account: return "此内容不属于当前 Emby 账户。"
        case .unsupported: return "此媒体源不支持当前的渐进式音频直放。"
        case .rateLimited: return "Emby 暂时限制播放请求，请等待约 30 秒后手动重试；不会自动重复请求。"
        case .noCompatibleStream: return "Emby 未提供与当前直放配置兼容的音频流；当前尚不支持转码播放。"
        case .missingSources: return "Emby 播放响应缺少媒体源信息，请稍后重试。"
        case .emptySources: return "Emby 未返回可用媒体源，请检查此曲目是否仍可访问。"
        case .playbackError: return "Emby 返回未识别的播放错误，请查看脱敏播放诊断。"
        case .unverifiedAudio: return "无法确认音频的容器与编码是否适合直放；未尝试未知格式。"
        case .liveStream: return "此媒体源需要打开或维护直播会话，当前尚不支持。"
        case .transcodingRequired: return "此音频无法按当前配置直放，可能需要服务端转码；当前尚不支持转码播放，请选择可直接播放的版本。"
        case .limit: return "本次只读取一个分页窗口，请继续加载或缩小搜索范围。"
        case .paging: return "服务端分页未前进或提前返回空页；已保留读取结果，请刷新后重试。"
        case .storage: return "Emby 本地安全存储不可用，请解锁设备并检查空间后重试。"
        case .remoteLogout: return "本机已退出；服务器注销未确认，可在 Emby 后台撤销设备会话。"
        }
    }
}

// PascalCase matches Emby's wire schema. Optional fields tolerate older servers.
struct EmbyUser: Decodable { let Id: String?; let Name: String? }
struct EmbyLogin: Decodable { let User: EmbyUser?; let AccessToken: String?; let ServerId: String? }
struct EmbyServer: Decodable { let Id: String? }
struct EmbyArtist: Decodable { let Name: String? }
struct EmbyItem: Decodable {
    let Id: String?; let Name: String?; let `Type`: String?; let MediaType: String?
    let RunTimeTicks: Int64?; let Album: String?; let AlbumId: String?
    let ArtistItems: [EmbyArtist]?; let Artists: [String]?; let PlaylistItemId: String?
    let Container: String?; let MediaStreams: [EmbyStream]?; let MediaSources: [EmbySource]?
    func song(scope: String) -> Song? {
        guard let id = Id, EmbyAddress.validID(id),
              Type == "Audio" || (Type == nil && MediaType == "Audio") else { return nil }
        let artists = ArtistItems?.compactMap(\.Name) ?? Artists ?? []
        return Song(platform: .emby, platformID: id, title: Name ?? "未知歌曲",
                    artist: artists.joined(separator: " / "), album: Album ?? "未知专辑",
                    duration: max(0, Double(RunTimeTicks ?? 0) / 10_000_000),
                    artworkURL: nil, albumID: AlbumId, accountScope: scope)
    }
}
struct EmbyPage: Decodable { let Items: [EmbyItem]?; let TotalRecordCount: Int? }
struct EmbyStream: Decodable { let `Type`: String?; let Codec: String? }
struct EmbySource: Decodable {
    let Id: String?; var Container: String?; let `Protocol`: String?
    let SupportsDirectPlay: Bool?; let SupportsDirectStream: Bool?; let SupportsTranscoding: Bool?
    let RequiresOpening: Bool?; let RequiresClosing: Bool?; let IsInfiniteStream: Bool?
    let RequiresLooping: Bool?; var MediaStreams: [EmbyStream]?
    // Never decode/use Path, DirectStreamUrl or TranscodingUrl as a request target.
    var needsSession: Bool {
        RequiresOpening == true || RequiresClosing == true || IsInfiniteStream == true || RequiresLooping == true
    }
    var directDenied: Bool {
        SupportsDirectPlay != true && SupportsDirectStream != true &&
        (SupportsDirectPlay == false || SupportsDirectStream == false)
    }
    var progressiveFormat: EmbyPlaybackPolicy.Format? {
        guard !needsSession, !directDenied,
              Protocol == nil || ["file", "http"].contains(Protocol!.lowercased()),
              let streams = MediaStreams,
              !streams.contains(where: { $0.Type?.lowercased() == "video" }),
              let codec = streams.first(where: { $0.Type?.lowercased() == "audio" })?.Codec?.lowercased()
        else { return nil }
        return EmbyPlaybackPolicy.format(container: Container, codec: codec)
    }
    var progressiveMIME: String? { progressiveFormat?.mime }
    func supplemented(by item: EmbyItem, onlySource: Bool) -> EmbySource {
        var result = self
        if let matching = item.MediaSources?.first(where: { $0.Id == Id }) {
            if result.MediaStreams?.isEmpty != false { result.MediaStreams = matching.MediaStreams }
            if result.Container == nil { result.Container = matching.Container }
        } else if onlySource && (item.MediaSources?.isEmpty != false) {
            if result.MediaStreams?.isEmpty != false { result.MediaStreams = item.MediaStreams }
            if result.Container == nil { result.Container = item.Container }
        }
        return result
    }
}

// Official PlaybackErrorCode is a string enum, not a success/error integer.
enum EmbyPlaybackError: Decodable {
    case notAllowed, noCompatibleStream, rateLimitExceeded, unknown
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        switch try? value.decode(String.self) {
        case "NotAllowed": self = .notAllowed
        case "NoCompatibleStream": self = .noCompatibleStream
        case "RateLimitExceeded": self = .rateLimitExceeded
        default: self = .unknown // Including numeric 0: never interpret as success.
        }
    }
    var failure: EmbyFailure {
        switch self {
        case .notAllowed: return .forbidden
        case .noCompatibleStream: return .noCompatibleStream
        case .rateLimitExceeded: return .rateLimited
        case .unknown: return .playbackError
        }
    }
}
struct EmbyInfo: Decodable { let MediaSources: [EmbySource]?; let ErrorCode: EmbyPlaybackError? }

enum EmbyPlaybackPolicy {
    struct Format { let fileExtension: String; let mime: String }
    // Explicit caps avoid older servers treating absent profile limits as zero.
    static let maxBitrate = 140_000_000
    private static let formats = [
        ("mp3", "mp3", "mp3", "audio/mpeg"),
        ("aac,adts", "aac", "aac", "audio/aac"),
        ("m4a,mp4", "aac,alac", "m4a", "audio/mp4"),
        ("flac", "flac", "flac", "audio/flac"),
        ("wav,wave", "pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le", "wav", "audio/wav")
    ]
    static func format(container: String?, codec: String) -> Format? {
        let containers = Set((container ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        for (names, codecs, ext, mime) in formats where
            !containers.isDisjoint(with: names.split(separator: ",").map(String.init)) &&
            codecs.split(separator: ",").contains(Substring(codec)) {
            return Format(fileExtension: ext, mime: mime)
        }
        return nil
    }
    static func request(user: String) -> [String: Any] {
        let profile: [String: Any] = ["Name": "TingFlow Progressive Audio", "SupportedMediaTypes": "Audio",
            "MaxStreamingBitrate": maxBitrate, "MaxStaticMusicBitrate": maxBitrate,
            "DirectPlayProfiles": formats.map { ["Container": $0.0, "AudioCodec": $0.1, "Type": "Audio"] },
            "TranscodingProfiles": []]
        return ["UserId": user, "MaxStreamingBitrate": maxBitrate,
                "EnableDirectPlay": true, "EnableDirectStream": true, "EnableTranscoding": false,
                "IsPlayback": true, "AutoOpenLiveStream": false, "DeviceProfile": profile]
    }
    static func select(_ sources: [EmbySource]) throws -> EmbySource {
        if let source = sources.first(where: { $0.Id.map(EmbyAddress.validID) == true && $0.progressiveFormat != nil }) { return source }
        guard sources.contains(where: { $0.Id.map(EmbyAddress.validID) == true }) else { throw EmbyFailure.response }
        if sources.contains(where: { $0.needsSession }) { throw EmbyFailure.liveStream }
        if sources.contains(where: { $0.directDenied }) { throw EmbyFailure.transcodingRequired }
        throw EmbyFailure.unverifiedAudio
    }
    static func resource(base: URL, item: String, source: EmbySource, token: String) throws -> PlaybackResource {
        guard let id = source.Id, EmbyAddress.validID(id), EmbyAddress.validToken(token),
              let format = source.progressiveFormat else { throw EmbyFailure.unverifiedAudio }
        // Always proxy through the authenticated configured server. Http describes the
        // server's source, NOT a destination to which the client's token may be sent.
        let url = try EmbyAddress.endpoint(base, ["Audio", item, "stream." + format.fileExtension], [
            URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "MediaSourceId", value: id)])
        return PlaybackResource(url: url, headers: ["X-Emby-Token": token], mimeType: format.mime,
                                isPreview: false, displayQuality: "原始音频", requiresResourceLoader: true)
    }
}

enum EmbyAddress {
    private static let segmentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value != "." && value != ".." &&
        !value.contains(where: { "/\\%\"\r\n".contains($0) }) &&
        value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    static func base(_ input: String) throws -> URL {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!) else { throw EmbyFailure.address }
        for part in c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(part).removingPercentEncoding,
                  decoded.isEmpty || validID(decoded) else { throw EmbyFailure.address }
        }
        c.scheme = "https"; c.host = host.lowercased()
        if c.port == 443 { c.port = nil }
        while c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath.removeLast() }
        guard let url = c.url else { throw EmbyFailure.address }
        return url
    }
    static func endpoint(_ base: URL, _ path: [String], _ query: [URLQueryItem] = []) throws -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw EmbyFailure.address }
        for part in path {
            guard validID(part), let encoded = part.addingPercentEncoding(withAllowedCharacters: segmentCharacters)
            else { throw EmbyFailure.response }
            c.percentEncodedPath += "/" + encoded
        }
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { throw EmbyFailure.address }
        return url
    }
    static func scope(base: URL, server: String, user: String) -> String {
        let data = (try? JSONEncoder().encode([base.absoluteString, server, user])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class EmbyNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Including same-origin authentication redirects.
    }
}

final class EmbyClient {
    let base: URL
    private let device: String
    private let session: URLSession
    init(base: URL, device: String, configuration: URLSessionConfiguration? = nil) {
        self.base = base; self.device = device
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: EmbyNoRedirects(), delegateQueue: nil)
    }
    func cancel() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
    func data(_ path: [String], query: [URLQueryItem] = [], token: String? = nil,
              user: String? = nil, body: [String: Any]? = nil, post: Bool = false) async throws -> Data {
        do {
            try Task.checkCancellation()
            let url = try EmbyAddress.endpoint(base, path, query)
            var r = URLRequest(url: url)
            r.httpMethod = post ? "POST" : "GET"
            var identity = "Emby Client=\"TingFlow\", Device=\"iOS\", DeviceId=\"\(device)\", Version=\"0.1\""
            if let user { guard EmbyAddress.validID(user) else { throw EmbyFailure.response }; identity += ", UserId=\"\(user)\"" }
            r.setValue(identity, forHTTPHeaderField: "X-Emby-Authorization")
            r.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                r.httpBody = try JSONSerialization.data(withJSONObject: body)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (bytes, response) = try await session.bytes(for: r)
            guard let h = response as? HTTPURLResponse else { throw EmbyFailure.response }
            switch h.statusCode {
            case 200..<300: break
            case 300..<400: throw EmbyFailure.redirect
            case 401: throw EmbyFailure.unauthorized
            case 403: throw EmbyFailure.forbidden
            case 429: throw EmbyFailure.rateLimited
            default: throw EmbyFailure.http(h.statusCode)
            }
            guard response.url == url else { throw EmbyFailure.redirect }
            var output = Data()
            for try await byte in bytes {
                guard output.count < 8 * 1024 * 1024 else { throw EmbyFailure.response }
                output.append(byte)
            }
            try Task.checkCancellation()
            return output
        } catch is CancellationError { throw CancellationError() }
        catch let error as EmbyFailure { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw EmbyFailure.network }
    }
    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw EmbyFailure.response }
    }
}
