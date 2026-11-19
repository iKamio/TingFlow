import Foundation
import CryptoKit

struct SourceCapability: Codable, Equatable {
    var actions: [String]
    var qualitys: [String]
    func compatibleQuality(_ requested: AudioQuality) -> AudioQuality? {
        let choices: [AudioQuality]
        switch requested {
        case .lossless: choices = [.lossless, .high, .standard]
        case .high: choices = [.high, .standard]
        case .standard: choices = [.standard]
        }
        return choices.first { qualitys.contains($0.rawValue) }
    }
    static func validate(_ data: [String: Any]) throws -> [String: SourceCapability] {
        guard let declared = data["sources"] as? [String: Any] else { throw SourceFailure.initialization }
        var result: [String: SourceCapability] = [:]
        for key in ["wy", "kg"] {
            guard let value = declared[key] as? [String: Any], value["type"] as? String == "music",
                  let actions = value["actions"] as? [String], let qualitys = value["qualitys"] as? [String] else { continue }
            let accepted = ["128k", "320k", "flac", "flac24bit"].filter { qualitys.contains($0) }
            if actions.contains("musicUrl"), !accepted.isEmpty {
                result[key] = SourceCapability(actions: ["musicUrl"], qualitys: accepted)
            }
        }
        guard !result.isEmpty else { throw SourceFailure.unsupported }
        return result
    }
}

struct UserSource: Identifiable, Codable, Equatable {
    enum State: String, Codable { case quarantined, idle, initializing, ready, failed }
    let id: UUID
    let sha256: String
    var name: String
    var version: String
    var author: String
    var description: String
    var isEnabled = false
    var isTrusted = false
    var allowedHosts: [String] = []
    var capabilities: [String: SourceCapability] = [:]
    var state: State = .quarantined
    var importedAt = Date()
    var statusText: String {
        switch state {
        case .quarantined: return "已隔离 · 尚未信任"
        case .idle: return "未运行 · 兼容性未验证"
        case .initializing: return "正在等待音源初始化"
        case .ready: return "声明校验完成 · 播放兼容性未验证"
        case .failed: return "运行失败 · 请检查兼容性与权限"
        }
    }
}

enum SourceFailure: String, Error, LocalizedError {
    case invalidScript, duplicate, initialization, unsupported, invalidURL, permission, network, redirect, tooLarge, busy, timeout, cancelled, retired, script, result, storage
    var errorDescription: String? {
        switch self {
        case .invalidScript: return "请选择不超过 1 MiB 的 UTF-8 JavaScript 文件。"
        case .duplicate: return "相同 SHA-256 的音源已经导入。"
        case .initialization: return "音源没有按协议注册 request 并发送有效的 inited。"
        case .unsupported: return "音源不支持此平台、动作、音质或所需工具。"
        case .invalidURL: return "只允许无用户信息、非私网 IP 的 HTTPS 精确域名地址（443 端口）。"
        case .permission: return "目标域名尚未得到你的授权，请在音源权限中添加精确域名。"
        case .network: return "音源网络请求失败（不会共享登录 Cookie 或系统凭据）。"
        case .redirect: return "第一版禁止所有 HTTP 重定向，请使用最终 HTTPS 地址。"
        case .tooLarge: return "音源文件或本次响应超过大小上限。"
        case .busy: return "该音源已有请求正在运行。"
        case .timeout: return "音源超时，已停止等待并隔离此运行实例；若脚本卡死，请重启应用。"
        case .cancelled: return "音源请求已取消；此实例已隔离，重新运行需要重启应用。"
        case .retired: return "该脚本实例已隔离；公共 JavaScriptCore 不能硬中断死循环，请重启应用后处理。"
        case .script: return "音源 JavaScript 抛错或 Promise 被拒绝，请核对 mobile 2.0 子集兼容性。"
        case .result: return "musicUrl 必须通过 Promise 返回已授权域名的 HTTPS URL 字符串。"
        case .storage: return "音源文件无法安全保存或读取。"
        }
    }
}

enum SourceURLPolicy {
    static func host(_ value: String) throws -> String {
        let h = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard h.utf8.count <= 253, labels.count >= 2,
              !h.hasSuffix(".localhost"), !h.hasSuffix(".local"), !h.hasSuffix(".lan"),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw SourceFailure.invalidURL }
        return h
    }
    static func hosts(_ input: String) throws -> [String] {
        let tokens = input.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))).filter { !$0.isEmpty }
        guard tokens.count <= 32 else { throw SourceFailure.permission }
        return try Array(Set(tokens.map { try host($0) })).sorted()
    }
    static func url(_ raw: String, allowed: [String]? = nil) throws -> URL {
        guard raw.utf8.count <= 2048, let c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.fragment == nil, c.port == nil || c.port == 443,
              let value = c.host, let url = c.url else { throw SourceFailure.invalidURL }
        let h = try host(value)
        if let allowed, !allowed.contains(h) { throw SourceFailure.permission }
        return url
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum SourceLegacyInfo {
    static func make(_ song: Song) -> [String: Any] {
        var types: [[String: Any]] = []
        var indexed: [String: Any] = [:]
        if song.platform == .kugou {
            for (type, hash) in [("128k", song.hash), ("320k", song.highQualityHash), ("flac", song.losslessHash)] {
                if let hash, !hash.isEmpty {
                    types.append(["type": type, "hash": hash])
                    indexed[type] = ["hash": hash]
                }
            }
        }
        let interval: Any
        if song.duration.isFinite && song.duration > 0 && song.duration < 864000 {
            let seconds = Int(song.duration)
            interval = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        } else { interval = NSNull() }
        var info: [String: Any] = ["name": song.title, "singer": song.artist, "source": song.platform.rawValue,
            "songmid": song.platformID, "interval": interval, "albumName": song.album,
            "albumId": song.albumID ?? "", "img": song.artworkURL?.absoluteString ?? "",
            "types": types, "_types": indexed, "typeUrl": [String: String]()]
        if song.platform == .kugou {
            if let hash = song.hash { info["hash"] = hash }
            // CatalogClient uses MixSongID when known, otherwise the file hash. Never invent MixSongID.
            if !song.platformID.isEmpty && song.platformID.utf8.allSatisfy({ (48...57).contains($0) }) {
                info["albumAudioId"] = song.platformID
            }
        }
        return info
    }
}
