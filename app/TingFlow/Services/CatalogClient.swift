import Foundation

private final class HTTPSOnlyDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

final class CatalogClient {
    private let session: URLSession
    init(configuration supplied: URLSessionConfiguration? = nil) {
        let configuration = supplied ?? URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: HTTPSOnlyDelegate(), delegateQueue: nil)
    }

    // These are platform web endpoints, not an official supported SDK.
    // Keep adapters independent: availability may change without notice.
    func search(_ query: String, platform: MusicPlatform, page: Int = 1) async throws -> [Song] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let url: URL
        var referer: String
        switch platform {
        case .netease:
            url = try makeURL("https://music.163.com/api/search/get", [
                "s": query, "type": "1", "limit": "30", "offset": String(max(0, page - 1) * 30)
            ])
            referer = "https://music.163.com/"
        case .kugou:
            url = try makeURL("https://songsearch.kugou.com/song_search_v2", [
                "keyword": query, "page": String(max(1, page)), "pagesize": "30",
                "userid": "-1", "platform": "WebFilter", "filter": "2"
            ])
            referer = "https://www.kugou.com/"
        case .local, .emby, .subsonic:
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 TingFlow/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MusicError.http(http.statusCode) }
        guard data.count < 4_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicError.invalidResponse
        }
        switch platform {
        case .netease:
            guard (root["code"] as? Int) == 200,
                  let result = root["result"] as? [String: Any] else { throw MusicError.invalidResponse }
            let songs = (result["songs"] as? [[String: Any]] ?? []).compactMap(parseNetease)
            return try await enrichNeteaseArtwork(songs)
        case .kugou:
            guard (root["status"] as? Int) == 1,
                  let result = root["data"] as? [String: Any] else { throw MusicError.invalidResponse }
            return (result["lists"] as? [[String: Any]] ?? []).compactMap(parseKugou)
        case .local, .emby, .subsonic:
            return []
        }
    }

    deinit { session.invalidateAndCancel() }

    /// A single anonymous batch, with the same cancellation as the search.
    /// Detail failure is optional: titles/order remain visible and playable.
    private func enrichNeteaseArtwork(_ songs: [Song]) async throws -> [Song] {
        let ids = CatalogArtworkMapping.idsNeedingArtwork(songs)
        guard !ids.isEmpty else { return songs }
        let url = try makeURL("https://music.163.com/api/song/detail/", ["ids": "[" + ids.joined(separator: ",") + "]"])
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 TingFlow/0.6", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == url,
                  (200..<300).contains(http.statusCode), data.count < 4_000_000,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["code"] as? Int == 200,
                  let details = root["songs"] as? [[String: Any]] else { return songs }
            return CatalogArtworkMapping.merging(songs, details: details, requested: ids)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return songs
        }
    }

    private func makeURL(_ path: String, _ parameters: [String: String]) throws -> URL {
        guard var components = URLComponents(string: path) else { throw MusicError.invalidURL }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MusicError.invalidURL }
        return url
    }
    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private func clean(_ input: String) -> String {
        input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func secureArtwork(_ value: String?) -> URL? {
        CatalogArtworkMapping.kugouArtwork(value)
    }
    private func parseNetease(_ item: [String: Any]) -> Song? {
        guard let id = string(item["id"]), let name = item["name"] as? String else { return nil }
        let album = item["album"] as? [String: Any] ?? item["al"] as? [String: Any] ?? [:]
        let artists = item["artists"] as? [[String: Any]] ?? item["ar"] as? [[String: Any]] ?? []
        return Song(platform: .netease, platformID: id, title: clean(name),
                    artist: artists.compactMap { $0["name"] as? String }.joined(separator: " / "),
                    album: album["name"] as? String ?? "", duration: (item["duration"] as? Double ?? 0) / 1000,
                    artworkURL: CatalogArtworkMapping.artwork(album["picUrl"]), albumID: string(album["id"]))
    }
    private func parseKugou(_ item: [String: Any]) -> Song? {
        guard let hash = string(item["FileHash"]),
              let name = item["SongName"] as? String ?? item["OriSongName"] as? String else { return nil }
        return Song(platform: .kugou, platformID: string(item["MixSongID"]) ?? hash,
                    title: clean(name), artist: clean(item["SingerName"] as? String ?? ""),
                    album: item["AlbumName"] as? String ?? "", duration: item["Duration"] as? Double ?? 0,
                    artworkURL: secureArtwork(item["Image"] as? String), albumID: string(item["AlbumID"]),
                    hash: hash, highQualityHash: string(item["HQFileHash"]), losslessHash: string(item["SQFileHash"]))
    }
}
