import Foundation

/// Entirely synthetic; no remote payload, credentials, avatar or account data.
enum SongCommentFixture {
    static func row(_ id: Any, content: Any = "合成评论") -> [String: Any] {
        ["commentId": id, "content": content, "user": ["nickname": "合成用户"], "likedCount": 3, "time": 1_700_000_000_000 as Int64]
    }
    static func root(_ rows: [[String: Any]], total: Any? = 123, more: Any = true, cursor: Any? = "1700000000000") -> [String: Any] {
        var data: [String: Any] = ["comments": rows, "hasMore": more]
        data["totalCount"] = total; data["cursor"] = cursor
        return ["code": 200, "data": data]
    }
    static func comment(_ id: String) -> SongComment {
        SongComment(id: id, nickname: "合成用户", content: "合成评论 " + id, time: nil, likes: 0, quote: nil)
    }
    static func page(_ ids: [String], more: Bool = true, cursor: String? = "1700000000000", total: Int? = nil) -> SongCommentPage {
        SongCommentPage(comments: ids.map(comment), total: total, more: more, cursor: cursor)
    }
    @MainActor final class Gate {
        private(set) var calls: [(CommentSort, Int, String?)] = []
        private var continuations: [CheckedContinuation<SongCommentPage, Error>] = []
        func read(_ sort: CommentSort, _ page: Int, _ cursor: String?) async throws -> SongCommentPage {
            calls.append((sort, page, cursor))
            // Deliberately ignores cancellation to exercise late callback isolation.
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func finish(_ index: Int, _ result: SongCommentPage) { continuations[index].resume(returning: result) }
        func fail(_ index: Int, _ error: Error) { continuations[index].resume(throwing: error) }
    }
}
