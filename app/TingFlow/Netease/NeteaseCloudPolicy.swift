import Foundation

/// Only fixed, user-safe messages; never include transport text, response bodies or URLs.
enum NeteaseCloudFailure: LocalizedError, Equatable {
    case invalidAccount, invalidInput, notOwner, unknownResult, unconfirmed, busy, needsRefresh
    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "请先登录当前网易云账号，再刷新云端资料库。"
        case .invalidInput: return "此歌曲或歌单不属于当前网易云账号上下文，无法同步。"
        case .notOwner: return "只能向当前账号自己创建的网易云歌单添加歌曲；自己的歌单不能收藏或取消收藏。"
        case .unknownResult, .unconfirmed: return "云端操作结果尚未确认，请手动刷新后查看。为避免重复操作，不会自动重试。"
        case .busy: return "正在核实另一项云端操作，请完成后再试。"
        case .needsRefresh: return "此项操作需要先手动刷新云端状态，确认后才能再次提交。"
        }
    }
}

/// Pure route/payload and bounded response parsing. A successful POST is never proof of state.
enum NeteaseCloudPolicy {
    static let maximumIDs = 100_000
    static func identifier(_ raw: String) throws -> String {
        guard let id = NeteaseMapping.id(raw), id == raw else { throw NeteaseCloudFailure.invalidInput }
        return id
    }
    static func likesPayload(uid: String) throws -> [String: Any] { ["uid": try identifier(uid)] }
    static func likePayload(id: String, liked: Bool) throws -> [String: Any] {
        ["alg": "itembased", "trackId": try identifier(id), "like": liked ? "true" : "false", "time": "3"]
    }
    static func subscription(_ subscribed: Bool) -> NeteaseClient.Endpoint {
        subscribed ? .subscribePlaylist : .unsubscribePlaylist
    }
    static func playlistPayload(id: String) throws -> [String: Any] { ["id": try identifier(id)] }
    static func detailPayload(id: String) throws -> [String: Any] {
        ["id": try identifier(id), "n": maximumIDs, "s": 0]
    }
    static func addPayload(songID: String, playlistID: String) throws -> [String: Any] {
        let song = try identifier(songID), list = try identifier(playlistID)
        // Validated positive decimal IDs form a JSON number array, NOT a Swift array description.
        return ["op": "add", "pid": list, "trackIds": "[\(song)]", "imme": "true"]
    }
    static func likedIDs(_ body: [String: Any]) throws -> Set<String> {
        guard let rows = body["ids"] as? [Any], rows.count <= maximumIDs else { throw NeteaseError.response }
        var result = Set<String>()
        for raw in rows {
            guard let id = NeteaseMapping.id(raw) else { throw NeteaseError.response }
            result.insert(id)
        }
        return result
    }
    struct Detail {
        let ownerID: String
        let trackIDs: Set<String>
    }
    static func detail(_ body: [String: Any], id: String) throws -> Detail {
        guard let row = body["playlist"] as? [String: Any], NeteaseMapping.id(row["id"]) == id,
              let creator = row["creator"] as? [String: Any], let owner = NeteaseMapping.id(creator["userId"]),
              let tracks = row["trackIds"] as? [[String: Any]], tracks.count <= maximumIDs,
              let count = row["trackCount"] as? Int, count == tracks.count else { throw NeteaseError.incomplete }
        var ids = Set<String>()
        for track in tracks {
            guard let id = NeteaseMapping.id(track["id"]) else { throw NeteaseError.response }
            ids.insert(id)
        }
        return Detail(ownerID: owner, trackIDs: ids)
    }
    static func mayHaveApplied(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? NeteaseError else { return true }
        switch error {
        case .network, .transientNetwork, .response: return true
        case .http(let code): return (500...599).contains(code)
        case .business(let code): return (500...599).contains(code) && code != 512
        default: return false
        }
    }
    static func safeMessage(_ error: Error) -> String {
        if let failure = error as? NeteaseCloudFailure { return failure.localizedDescription }
        return NeteaseError.message(error)
    }
}
