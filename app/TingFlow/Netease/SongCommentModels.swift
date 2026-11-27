import Foundation
import CoreFoundation

struct SongComment: Identifiable, Equatable {
    let id: String
    let nickname: String
    let content: String
    let time: Date?
    let likes: Int
    let quote: String?
}
enum CommentSort: Int, CaseIterable, Identifiable {
    case hot = 2, latest = 3
    var id: Int { rawValue }
    var title: String { self == .hot ? "热门" : "最新" }
}
struct SongCommentPage {
    let comments: [SongComment]
    let total: Int?
    let more: Bool
    let cursor: String?
}
enum SongCommentError: LocalizedError {
    case timedOut
    var errorDescription: String? { "评论请求超时，请重试。" }
}
/// Matches api-enhanced/module/comment_new.js. No arbitrary routes or avatar URLs.
enum SongCommentMapping {
    static let pageSize = 20
    static let maximumPages = 50
    static let maximumComments = pageSize * maximumPages
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) } && value.contains { $0 != "0" }
    }
    static func validCursor(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }
    static func payload(songID: String, sort: CommentSort, page: Int, cursor: String?) throws -> [String: Any] {
        guard validID(songID), (1...maximumPages).contains(page) else { throw NeteaseError.response }
        let next: String
        if sort == .hot { next = "normalHot#\((page - 1) * pageSize)" }
        else {
            next = page == 1 ? "0" : (cursor ?? "")
            guard validCursor(next) else { throw NeteaseError.incomplete }
            if page > 1 && next == "0" { throw NeteaseError.incomplete }
        }
        return ["threadId": "R_SO_4_" + songID, "pageNo": page, "pageSize": pageSize,
                "showInner": true, "sortType": sort.rawValue, "cursor": next]
    }
    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String else { return nil }
        // Bound work before filtering and remove bidi/control overrides from untrusted text.
        let scalars = value.unicodeScalars.prefix(limit * 4).filter {
            $0 == "\n" || $0 == "\t" || (!CharacterSet.controlCharacters.contains($0) &&
                !(0x202a...0x202e).contains($0.value) && !(0x2066...0x2069).contains($0.value))
        }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(limit))
    }
    /// JSON booleans and floating point NSNumbers must NEVER become comment IDs/counts.
    private static func integerString(_ value: Any?) -> String? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: value.objCType)) else { return nil }
        return value.stringValue
    }
    private static func integer(_ value: Any?) -> Int? {
        integerString(value).flatMap(Int.init)
    }
    private static func identifier(_ value: Any?) -> String? {
        let candidate = (value as? String) ?? integerString(value)
        guard let candidate, validID(candidate) else { return nil }
        return String(candidate.drop(while: { $0 == "0" }))
    }
    private static func cursor(_ value: Any?) -> String? {
        guard let result = (value as? String) ?? integerString(value), validCursor(result) else { return nil }
        return result
    }
    static func decode(_ root: [String: Any]) throws -> SongCommentPage {
        guard integer(root["code"]) == 200, let data = root["data"] as? [String: Any],
              let rows = data["comments"] as? [[String: Any]], rows.count <= pageSize,
              let moreNumber = data["hasMore"] as? NSNumber,
              CFGetTypeID(moreNumber) == CFBooleanGetTypeID() else { throw NeteaseError.response }
        var seen = Set<String>()
        let comments: [SongComment] = rows.compactMap { row in
            // Validate before inserting into seen: a malformed first row must not hide a valid duplicate.
            guard let id = identifier(row["commentId"]), let content = text(row["content"], limit: 10000),
                  seen.insert(id).inserted else { return nil }
            let user = row["user"] as? [String: Any] ?? [:]
            let likes = min(1_000_000_000, max(0, integer(row["likedCount"]) ?? 0))
            let milliseconds = integer(row["time"]) ?? 0
            let date = milliseconds > 0 && milliseconds < 10_000_000_000_000 ? Date(timeIntervalSince1970: Double(milliseconds) / 1000) : nil
            let reply = (row["beReplied"] as? [[String: Any]])?.first
            return SongComment(id: id, nickname: text(user["nickname"], limit: 100) ?? "网易云用户",
                               content: content, time: date, likes: likes, quote: text(reply?["content"], limit: 2000))
        }
        guard rows.isEmpty || !comments.isEmpty else { throw NeteaseError.response }
        let total = integer(data["totalCount"]).flatMap { (0...1_000_000_000).contains($0) ? $0 : nil }
        return SongCommentPage(comments: comments, total: total, more: moreNumber.boolValue, cursor: cursor(data["cursor"]))
    }
}
