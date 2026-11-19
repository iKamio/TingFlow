import Foundation
import CoreFoundation

struct NeteasePlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let trackCount: Int
    let coverURL: URL?
    let ownerName: String
    let accountScope: String
    var ownerID: String? = nil
    var isPrivate = false
    var isLiked = false
}

struct NeteaseFeaturedPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let coverURL: URL?
    let playCount: Int
    let trackCount: Int
}

enum NeteaseError: LocalizedError, Equatable {
    case network, response, rejected, signedOut, identity, crypto, unavailable, incomplete, unsafeURL, storage
    case recommendation, verification, rateLimited, transientNetwork
    case business(Int), http(Int), mediaRejected(Int)
    case drmRestricted
    case playbackVerification(Int)
    var errorDescription: String? {
        switch self {
        case .network, .transientNetwork: return "无法连接网易云，请检查网络后重试。"
        case .response: return "网易云接口返回格式已变化，当前版本暂不支持。"
        case .rejected: return "网易云暂不允许此请求，可能需要在官方 App 完成验证。"
        case .signedOut: return "网易云会话已失效，请重新扫码登录。"
        case .identity: return "无法核实网易云账号身份，请重新扫码。"
        case .crypto: return "当前系统不支持网易云请求加密。"
        case .unavailable: return "平台未提供可播放地址，可能受会员、版权或地区权限限制。"
        case .incomplete: return "歌单数据不完整或超过本版本限制，请稍后重新载入。"
        case .unsafeURL: return "平台返回的媒体地址或格式不受当前安全策略支持。"
        case .storage: return "无法访问或清除设备安全凭据，请解锁设备后重试。"
        case .recommendation: return "网易云推荐暂时不可用；不会用示例数据替代你的真实推荐。"
        case .verification: return "网易云要求额外安全验证，请在官方 App 检查账号后重试（不会绕过验证）。"
        case .playbackVerification(let code): return "网易云拒绝本次播放请求（安全验证码 \(code)），尚未返回音频。账号可登录与播放接口获准是两回事；已停止重试和自动换源。请查看播放诊断，本应用不能替代平台验证。"
        case .rateLimited: return "网易云请求过于频繁，请稍后重试。"
        case .business(let code): return "网易云拒绝此请求（接口码 \(code)）；请稍后重试或在官方 App 检查账号。"
        case .http(let code): return "网易云网络请求失败（HTTP \(code)）。"
        case .mediaRejected(let code): return "网易云未接受此音频请求（媒体码 \(code)），已停止尝试，请查看播放诊断。"
        case .drmRestricted: return "平台返回受保护音频，当前播放器不能播放，也不会自动改换来源。"
        }
    }
    static func message(_ error: Error) -> String {
        (error as? NeteaseError)?.errorDescription ?? "操作未完成，请稍后重试。"
    }
}

enum NeteaseMapping {
    static func id(_ value: Any?) -> String? {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            text = number.stringValue
        } else { return nil }
        guard !text.isEmpty, text.count <= 20, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(text), value > 0 else { return nil }
        return String(value)
    }
    static func identity(_ body: [String: Any]) throws -> (id: String, name: String, avatar: URL?) {
        guard let profile = body["profile"] as? [String: Any], let uid = id(profile["userId"]) else { throw NeteaseError.identity }
        if let account = body["account"] as? [String: Any], id(account["id"]) != uid { throw NeteaseError.identity }
        return (uid, profile["nickname"] as? String ?? "网易云用户", artworkURL(profile["avatarUrl"] as? String))
    }
    static func mediaURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased(),
              host == "music.163.com" || host.hasSuffix(".music.163.com") ||
              host == "music.126.net" || host.hasSuffix(".music.126.net") else { return nil }
        if scheme == "https" { return url.port == nil || url.port == 443 ? url : nil }
        // Platform often returns HTTP CDN URLs. Upgrade only the known official music CDN;
        // never permit cleartext, change the host/path/query, or infer playback permission.
        guard scheme == "http", host == "music.126.net" || host.hasSuffix(".music.126.net"),
              url.port == nil || url.port == 80,
              var secure = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        secure.scheme = "https"
        secure.port = nil
        return secure.url
    }
    private static let artworkHosts = Set((1...6).flatMap { ["p\($0).music.126.net", "p\($0).music.163.com"] })
    static func artworkURL(_ raw: String?) -> URL? {
        guard let raw, raw.utf8.count <= 4096, raw.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              let url = mediaURL(raw), let host = url.host?.lowercased(), artworkHosts.contains(host),
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    static func song(_ row: [String: Any], scope: String) -> Song? {
        guard let songID = id(row["id"]) else { return nil }
        let album = row["al"] as? [String: Any] ?? row["album"] as? [String: Any] ?? [:]
        let artists = ((row["ar"] as? [[String: Any]]) ?? (row["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        return Song(platform: .netease, platformID: songID, title: row["name"] as? String ?? "未知歌曲",
                    artist: artists.joined(separator: " / "), album: album["name"] as? String ?? "",
                    duration: max(0, ((row["dt"] ?? row["duration"]) as? NSNumber)?.doubleValue ?? 0) / 1000,
                    artworkURL: artworkURL(album["picUrl"] as? String), albumID: id(album["id"]), accountScope: scope)
    }
    /// Detail response order is not authoritative. Rebuild from trackIds, including duplicates and missing IDs.
    static func orderedSongs(ids: [String], details: [[String: Any]], scope: String) -> [Song] {
        var indexed: [String: Song] = [:]
        for row in details { if let item = song(row, scope: scope) { indexed[item.platformID] = item } }
        return ids.map { indexed[$0] ?? Song(platform: .netease, platformID: $0,
            title: "暂不可用的歌曲", artist: "平台未返回详情", album: "", duration: 0, accountScope: scope) }
    }
    static func playback(_ body: [String: Any], songID: String) throws -> PlaybackResource {
        guard let rows = body["data"] as? [[String: Any]],
              let row = rows.first(where: { id($0["id"]) == songID }) else { throw NeteaseError.response }
        if row["isDRM"] as? Bool == true { throw NeteaseError.drmRestricted }
        guard let code = row["code"] as? Int else { throw NeteaseError.response }
        try NeteasePlaybackSafety.validateMediaCode(code)
        guard let raw = row["url"] as? String, !raw.isEmpty else { throw NeteaseError.unavailable }
        guard let url = mediaURL(raw) else { throw NeteaseError.unsafeURL }
        let kind = (row["type"] as? String ?? "").lowercased()
        let mime: String
        switch kind {
        case "mp3": mime = "audio/mpeg"
        case "flac": mime = "audio/flac"
        case "m4a", "mp4": mime = "audio/mp4"
        case "aac": mime = "audio/aac"
        default: throw NeteaseError.unsafeURL
        }
        if let flag = row["isDRM"] as? Bool, flag { throw NeteaseError.unavailable }
        let trial = row["freeTrialInfo"].map { !($0 is NSNull) && String(describing: $0) != "null" } ?? false
        let bitrate = row["br"] as? Int ?? 0
        return PlaybackResource(url: url, mimeType: mime, isPreview: trial,
            displayQuality: NeteaseAudioPolicy.displayQuality(type: kind, bitrate: bitrate,
                level: row["level"] as? String, isPreview: trial))
    }
    static func playlist(_ row: [String: Any], scope: String) -> NeteasePlaylist? {
        guard let id = id(row["id"]) else { return nil }
        let creator = row["creator"] as? [String: Any] ?? [:]
        return NeteasePlaylist(id: id, name: row["name"] as? String ?? "未命名歌单",
            trackCount: (row["trackCount"] as? NSNumber)?.intValue ?? 0,
            coverURL: artworkURL(row["coverImgUrl"] as? String ?? row["picUrl"] as? String),
            ownerName: creator["nickname"] as? String ?? "", accountScope: scope,
            ownerID: self.id(creator["userId"]), isPrivate: (row["privacy"] as? Int) == 10,
            isLiked: (row["specialType"] as? Int) == 5)
    }
    static func featuredPlaylist(_ row: [String: Any]) -> NeteaseFeaturedPlaylist? {
        guard let id = id(row["id"]), let title = row["name"] as? String, !title.isEmpty else { return nil }
        return NeteaseFeaturedPlaylist(id: id, name: title,
            description: (row["copywriter"] as? String) ?? (row["description"] as? String) ?? "",
            coverURL: artworkURL((row["picUrl"] as? String) ?? (row["coverImgUrl"] as? String)),
            playCount: (row["playCount"] as? NSNumber)?.intValue ?? 0,
            trackCount: (row["trackCount"] as? NSNumber)?.intValue ?? 0)
    }
    static func dailySongs(_ body: [String: Any], scope: String) throws -> [Song] {
        // Some valid, newly created accounts have no recommendation history yet.
        if body["data"] is NSNull { return [] }
        guard let data = body["data"] as? [String: Any], let rows = data["dailySongs"] as? [[String: Any]] else { throw NeteaseError.response }
        return rows.compactMap { song($0, scope: scope) }
    }
    static func featuredPlaylists(_ body: [String: Any]) throws -> [NeteaseFeaturedPlaylist] {
        guard let rows = body["recommend"] as? [[String: Any]] else { throw NeteaseError.response }
        return rows.compactMap(featuredPlaylist)
    }
    static func personalizedPlaylists(_ body: [String: Any]) throws -> [NeteaseFeaturedPlaylist] {
        guard let rows = body["result"] as? [[String: Any]] else { throw NeteaseError.response }
        return rows.compactMap(featuredPlaylist)
    }
}
