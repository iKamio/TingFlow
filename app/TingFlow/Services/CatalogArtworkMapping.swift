import Foundation

/// Exact-ID enrichment only. Search metadata is never replaced by a fuzzy match.
enum CatalogArtworkMapping {
    static func idsNeedingArtwork(_ songs: [Song]) -> [String] {
        var seen = Set<String>()
        return songs.compactMap { song in
            guard song.platform == .netease, song.accountScope == nil, song.artworkURL == nil,
                  validID(song.platformID), seen.insert(song.platformID).inserted else { return nil }
            return song.platformID
        }.prefix(30).map { $0 }
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) } && value.contains { $0 != "0" }
    }
    static func artwork(_ value: Any?) -> URL? {
        guard let raw = value as? String, raw.utf8.count <= 2048,
              var parts = URLComponents(string: raw), parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              ["music.126.net", "music.163.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        guard parts.scheme?.lowercased() == "https" else { return nil }
        if let query = parts.percentEncodedQuery {
            guard let items = URLComponents(string: "https://fixture.invalid/?" + query)?.queryItems,
                  items.count == 1, items[0].name == "param", let value = items[0].value,
                  value.range(of: #"^[0-9]{2,4}y[0-9]{2,4}$"#, options: .regularExpression) != nil else { return nil }
            // The legacy catalog resizes its own trusted image URL using `?param=WxH`.
            // Remove only that exact harmless transform and load the original cover from HTTPS.
            parts.query = nil
        }
        return parts.url
    }
    static func kugouArtwork(_ value: Any?) -> URL? {
        guard let raw = value as? String, raw.utf8.count <= 2048,
              var parts = URLComponents(string: raw.replacingOccurrences(of: "{size}", with: "480")),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, parts.query == nil,
              let host = parts.host?.lowercased(),
              ["imge.kugou.com", "imgessl.kugou.com", "singerimg.kugou.com"].contains(host) else { return nil }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        guard parts.scheme?.lowercased() == "https" else { return nil }
        return parts.url
    }
    static func merging(_ songs: [Song], details: [[String: Any]], requested: [String]) -> [Song] {
        let allowed = Set(requested)
        var images: [String: URL] = [:]
        for row in details.prefix(30) {
            let id: String?
            if let raw = row["id"] as? String { id = raw }
            else if let raw = row["id"] as? NSNumber { id = raw.stringValue }
            else { id = nil }
            guard let id, validID(id), allowed.contains(id), images[id] == nil else { continue }
            let album = row["al"] as? [String: Any] ?? row["album"] as? [String: Any] ?? [:]
            if let image = artwork(album["picUrl"]) { images[id] = image }
        }
        return songs.map { song in
            guard song.platform == .netease, song.accountScope == nil, song.artworkURL == nil,
                  let image = images[song.platformID] else { return song }
            var updated = song; updated.artworkURL = image
            return updated
        }
    }
}
