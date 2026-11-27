import Foundation

enum EnhancedMatchSource: String, Codable, CaseIterable, Identifiable {
    case automatic = "", unm, byfuns, ddyr, gdmusic, msls, oi, qijieya
    var id: String { rawValue }
    var title: String { self == .automatic ? "自动匹配" : rawValue }
}

struct EnhancedMatchConfiguration: Codable, Equatable {
    var enabled = false
    var address = "https://api-enhanced-psi-khaki.vercel.app"
    var source = EnhancedMatchSource.msls

    func baseURL() throws -> URL {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = try? SourceURLPolicy.url(value), url.query == nil else {
            throw EnhancedMatchFailure.address
        }
        return url
    }

    func requestURL(songID: String) throws -> URL {
        guard !songID.isEmpty, songID.count <= 20, songID.first != "0",
              songID.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(songID) != nil else {
            throw EnhancedMatchFailure.response
        }
        let endpoint = try baseURL().appendingPathComponent("song/url/match")
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw EnhancedMatchFailure.address
        }
        parts.queryItems = [URLQueryItem(name: "id", value: songID), URLQueryItem(name: "noCookie", value: "true")]
        if source != .automatic { parts.queryItems?.append(URLQueryItem(name: "source", value: source.rawValue)) }
        guard let url = parts.url else { throw EnhancedMatchFailure.address }
        return url
    }
}

enum EnhancedMatchFailure: LocalizedError {
    case address, unavailable, response, network, unsafeMedia
    var errorDescription: String? {
        switch self {
        case .address: return "请先保存不含账号、密码、查询参数或片段的公网 HTTPS API 地址。"
        case .unavailable: return "匹配服务未找到可用音频，请尝试其它模块或稍后重试。"
        case .response: return "匹配接口返回格式无法识别，请确认服务支持 /song/url/match。"
        case .network: return "无法连接匹配服务，请检查服务地址与网络。"
        case .unsafeMedia: return "匹配服务没有返回可直接播放的 HTTPS 音频地址；HTTP 或重定向音源需要服务端提供支持 Range 的 HTTPS 代理。"
        }
    }
}

private final class EnhancedMatchNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Separate anonymous transport: platform login state never enters this session.
/// No audio URLs, response bodies or server error text are persisted or logged.
final class EnhancedMatchClient {
    private let session: URLSession
    init(configuration supplied: URLSessionConfiguration? = nil) {
        let config = supplied ?? .ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 18
        session = URLSession(configuration: config, delegate: EnhancedMatchNoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func playback(for song: Song, configuration: EnhancedMatchConfiguration) async throws -> PlaybackResource {
        guard configuration.enabled, song.platform == .netease else { throw EnhancedMatchFailure.unavailable }
        let url = try configuration.requestURL(songID: song.platformID)
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { throw EnhancedMatchFailure.response }
            guard http.statusCode == 200 else { throw EnhancedMatchFailure.unavailable }
            guard response.expectedContentLength <= 64_000 else { throw EnhancedMatchFailure.response }
            var body = Data()
            for try await byte in bytes {
                guard body.count < 64_000 else { throw EnhancedMatchFailure.response }
                body.append(byte)
            }
            try Task.checkCancellation()
            data = body
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw (error as? EnhancedMatchFailure) ?? .network
        }
        return try Self.resource(data, source: configuration.source)
    }

    static func resource(_ data: Data, source: EnhancedMatchSource) throws -> PlaybackResource {
        guard data.count <= 64_000,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = root["code"] as? Int else { throw EnhancedMatchFailure.response }
        guard code == 200 else { throw EnhancedMatchFailure.unavailable }
        guard let direct = root["data"] as? String, !direct.isEmpty else { throw EnhancedMatchFailure.unavailable }
        // A server-provided HTTPS proxy may also resolve an upstream redirect or
        // required headers. Validate each candidate before choosing one.
        let candidates: [String] = [root["proxyUrl"] as? String, direct].compactMap { $0 }
        guard let url = candidates.lazy.compactMap({ try? SourceURLPolicy.url($0) })
            .first(where: { !["m3u", "m3u8", "mpd"].contains($0.pathExtension.lowercased()) }) else {
            throw EnhancedMatchFailure.unsafeMedia
        }
        return PlaybackResource(url: url, displayQuality: "匹配音频 · 音质未验证", requiresResourceLoader: true,
                                sourceLabel: "api-enhanced · " + source.title)
    }
}
