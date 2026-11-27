import Foundation
import CoreFoundation
import CryptoKit

/// Defensive mapping for the standard app cloud-list response family. Unknown shapes fail, never demo data.
enum KugouMapping {
    static func text(_ value: Any?, max: Int = 512) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= max,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return clean
    }
    static func decimal(_ value: Any?, max: Int = 20) -> String? {
        let string: String
        if let value = value as? String { string = value }
        else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { string = n.stringValue }
        else { return nil }
        guard !string.isEmpty, string.utf8.count <= max, string.utf8.allSatisfy({ (48...57).contains($0) }),
              string == "0" || string.first != "0" else { return nil }
        return string
    }
    static func int(_ value: Any?) -> Int? { decimal(value).flatMap(Int.init) }
    static func hash(_ value: Any?) -> String? {
        guard let s = value as? String, s.count == 32, s.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              s != String(repeating: "0", count: 32) else { return nil }
        return s.uppercased()
    }
    /// Only unsigned public KuGou CDN artwork. No arbitrary URLs, userinfo, queries or redirects with tokens.
    static func artwork(_ value: Any?) -> URL? {
        guard let string = value as? String, string.utf8.count < 2048,
              var c = URLComponents(string: string.replacingOccurrences(of: "{size}", with: "480")),
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              let host = c.host?.lowercased(), ["imge.kugou.com", "singerimg.kugou.com", "imgessl.kugou.com"].contains(host),
              c.scheme == "https" || c.scheme == "http" else { return nil }
        c.scheme = "https"; return c.url
    }
    static func data(_ root: [String: Any]) throws -> [String: Any] {
        guard let data = root["data"] as? [String: Any] else { throw KugouError.response }; return data
    }
    static func qrKey(_ root: [String: Any]) throws -> String {
        let data = try data(root)
        guard let key = data["qrcode"] as? String, validQRKey(key) else { throw KugouError.response }; return key
    }
    static func validQRKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 256 && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func qrURL(_ key: String) throws -> URL {
        guard validQRKey(key), var c = URLComponents(string: "https://h5.kugou.com/apps/loginQRCode/html/index.html") else { throw KugouError.response }
        c.queryItems = [URLQueryItem(name: "qrcode", value: key)]
        guard let url = c.url else { throw KugouError.response }; return url
    }
    static func qrResult(_ root: [String: Any], device: KugouDevice) throws -> KugouQRResult {
        let data = try data(root)
        switch int(data["status"]) {
        case 0: return .expired
        case 1: return .waiting
        case 2: return .scanned
        case 4:
            guard let uid = decimal(data["userid"]), let token = data["token"] as? String else { throw KugouError.response }
            return .authorized(try KugouCredential(userID: uid, token: token, device: device))
        default: throw KugouError.response
        }
    }
    static func profile(_ root: [String: Any], expected: String) throws -> KugouProfile {
        let body = try data(root), info = body["userinfo"] as? [String: Any] ?? body
        guard let uid = decimal(info["userid"] ?? info["user_id"]), uid == expected else { throw KugouError.identity }
        return KugouProfile(id: uid, name: text(info["nickname"] ?? info["username"]) ?? "酷狗用户", avatar: artwork(info["pic"] ?? info["user_pic"] ?? info["avatar"]))
    }
    private static func rows(_ body: [String: Any]) throws -> [[String: Any]] {
        guard let rows = (body["info"] ?? body["list"] ?? body["lists"]) as? [[String: Any]], rows.count <= 300 else { throw KugouError.response }; return rows
    }
    private static func total(_ body: [String: Any]) throws -> Int? {
        // An unverified `count` may mean rows in this page, not account-wide total.
        // Without an explicit total, keep paging until a short/empty page (or fail at cap).
        guard let value = body["total"] ?? body["total_count"] else { return nil }
        guard let n = int(value), n <= 60000 else { throw KugouError.pagination }; return n
    }
    static func playlists(_ root: [String: Any], uid: String) throws -> KugouPage<KugouPlaylist> {
        let body = try data(root), values = try rows(body), scope = "kugou:\(uid)"
        let items: [KugouPlaylist] = try values.map { row in
            guard let id = decimal(row["listid"]), let name = text(row["name"] ?? row["listname"]) else { throw KugouError.response }
            let owner = decimal(row["list_create_userid"] ?? row["create_userid"] ?? row["userid"])
            let kind: KugouPlaylist.Kind = owner.map { $0 == uid ? .created : .collected } ?? .unknown
            return KugouPlaylist(id: id, accountScope: scope, name: name, ownerID: owner,
                trackCount: int(row["count"] ?? row["filecount"] ?? row["song_count"]) ?? 0,
                artworkURL: artwork(row["pic"] ?? row["cover"] ?? row["imgurl"]), kind: kind,
                globalCollectionID: text(row["global_collection_id"], max: 128))
        }
        return KugouPage(items: items, total: try total(body), rawCount: values.count, fingerprint: digest(items.map(\.id).joined(separator: ",")))
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

extension KugouMapping {
    static func tracks(_ root: [String: Any], scope: String) throws -> KugouPage<Song> {
        let body = try data(root), values = try rows(body)
        let songs = try values.map { row -> Song in
            let audio = row["audio_info"] as? [String: Any] ?? [:]
            let album = row["album_info"] as? [String: Any] ?? [:]
            guard let hash = hash(row["hash"] ?? row["filehash"] ?? audio["hash"]) else { throw KugouError.response }
            let fileName = text(row["filename"] ?? row["name"])
            let parts = fileName?.components(separatedBy: " - ") ?? []
            guard let title = text(row["songname"] ?? row["song_name"]) ?? (parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : fileName), !title.isEmpty else { throw KugouError.response }
            let authors = (row["authors"] as? [[String: Any]] ?? []).compactMap { text($0["author_name"] ?? $0["name"]) }.joined(separator: " / ")
            guard authors.utf8.count <= 1024 else { throw KugouError.response }
            let artist = text(row["singername"] ?? row["singer_name"]) ?? (!authors.isEmpty ? authors : (parts.count > 1 ? parts[0] : ""))
            let milliseconds = int(row["timelen"] ?? row["timelength"] ?? audio["timelength"]) ?? 0
            let seconds = int(row["duration"]) ?? 0
            let mixID = decimal(row["mixsongid"] ?? row["mixsong_id"] ?? row["album_audio_id"])
            // album_audio_id/mixsongid supplies LX's albumAudioId; hash is always retained for playback.
            return Song(platform: .kugou, platformID: mixID.flatMap { $0 == "0" ? nil : $0 } ?? hash,
                title: title, artist: artist, album: text(row["album_name"] ?? album["album_name"]) ?? "",
                duration: min(86400, milliseconds > 0 ? Double(milliseconds) / 1000 : Double(seconds)),
                artworkURL: artwork(row["cover"] ?? row["sizable_cover"] ?? album["sizable_cover"]),
                albumID: decimal(row["album_id"] ?? album["album_id"]), hash: hash,
                highQualityHash: Self.hash(row["320hash"] ?? row["hash_320"] ?? row["hqhash"] ?? audio["hash_320"]),
                losslessHash: Self.hash(row["sqhash"] ?? row["hash_flac"] ?? audio["hash_flac"]), accountScope: scope)
        }
        return KugouPage(items: songs, total: try total(body), rawCount: values.count,
                        fingerprint: digest(songs.map { $0.platformID + ":" + ($0.hash ?? "") }.joined(separator: ",")))
    }
}
