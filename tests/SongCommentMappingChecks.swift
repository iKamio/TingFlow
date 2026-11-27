import Foundation

@main struct SongCommentMappingChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1 }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(label) } catch { count += 1 }
        }
        typealias F = SongCommentFixture
        let hot = try SongCommentMapping.payload(songID: "123456789", sort: .hot, page: 3, cursor: "untrusted-stale")
        check(hot["threadId"] as? String == "R_SO_4_123456789", "uses actual song ID, not title or playlist ID")
        check(hot["sortType"] as? Int == 2 && hot["pageNo"] as? Int == 3 && hot["pageSize"] as? Int == 20, "hot contract")
        check(hot["cursor"] as? String == "normalHot#40", "hot uses offset not previous time cursor")
        let latest = try SongCommentMapping.payload(songID: "9", sort: .latest, page: 1, cursor: "stale")
        check(latest["cursor"] as? String == "0" && latest["sortType"] as? Int == 3, "latest first page starts fresh")
        let next = try SongCommentMapping.payload(songID: "9", sort: .latest, page: 2, cursor: "1700000000000")
        check(next["cursor"] as? String == "1700000000000", "latest server cursor preserved")
        for id in ["", "0", "000", "-1", "1.5", "1e3", "１２", "1/2", String(repeating: "1", count: 21)] {
            rejects("invalid song ID") { _ = try SongCommentMapping.payload(songID: id, sort: .hot, page: 1, cursor: nil) }
        }
        for page in [0, -1, 51] {
            rejects("page bounds") { _ = try SongCommentMapping.payload(songID: "1", sort: .hot, page: page, cursor: nil) }
        }
        let badCursors: [String?] = [nil, "", "0", "x\n", String(repeating: "a", count: 257)]
        for cursor in badCursors {
            rejects("invalid latest continuation") { _ = try SongCommentMapping.payload(songID: "1", sort: .latest, page: 2, cursor: cursor) }
        }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SongCommentSynthetic.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let decoded = try SongCommentMapping.decode(raw)
        check(decoded.comments.map(\.id) == ["9007199254740993", "42"], "string ID beyond JS safe integer is exact")
        check(decoded.total == 2 && !decoded.more && decoded.comments[1].quote != nil, "total/end/quote from fixture")
        check(decoded.comments[0].content.contains("<b>"), "mapper preserves literal text, view never interprets markup")
        let rows = [F.row("001", content: " "), F.row("1", content: "valid after invalid"), F.row(1, content: "duplicate"),
                    F.row(true), F.row(NSNumber(value: 2.0)), F.row(2.5), F.row("3.0"), F.row("-4"), F.row("5", content: NSNull()), F.row(UInt64.max)]
        let mapped = try SongCommentMapping.decode(F.root(rows))
        check(mapped.comments.map(\.id) == ["1", String(UInt64.max)], "booleans/floats rejected; invalid row cannot consume valid ID; aliases deduped")
        let limited = try SongCommentMapping.decode(F.root([F.row("1", content: String(repeating: "长", count: 12000))], total: true))
        check(limited.comments[0].content.count == 10000 && limited.total == nil, "text bounded, boolean total not invented")
        var row = F.row("1"); row["user"] = ["nickname": String(repeating: "名", count: 200) + "\u{202E}"]
        row["beReplied"] = [["content": String(repeating: "引", count: 3000)]]
        row["likedCount"] = true; row["time"] = true
        let bounded = try SongCommentMapping.decode(F.root([row], total: 2.5))
        check(bounded.comments[0].nickname.count == 100 && bounded.comments[0].quote?.count == 2000, "nickname/quote bounds")
        check(bounded.comments[0].likes == 0 && bounded.comments[0].time == nil && bounded.total == nil, "metadata bool/float never coerced")
        check(try SongCommentMapping.decode(F.root([], total: nil, more: false, cursor: nil)).total == nil, "missing total stays unknown")
        check(try SongCommentMapping.decode(F.root([], total: 0, more: false)).total == 0, "server zero retained")
        rejects("malformed envelope") { _ = try SongCommentMapping.decode(["code": 200]) }
        rejects("business error not empty") { _ = try SongCommentMapping.decode(["code": 301, "data": [:]]) }
        rejects("numeric more not boolean") { _ = try SongCommentMapping.decode(F.root([], more: 1)) }
        rejects("all malformed rows not empty success") { _ = try SongCommentMapping.decode(F.root([F.row(true)])) }
        rejects("oversized page") { _ = try SongCommentMapping.decode(F.root(Array(repeating: F.row("1"), count: 21))) }
        let numericCursor = try SongCommentMapping.decode(F.root([], cursor: Int64(1700000000000)))
        check(numericCursor.cursor == "1700000000000", "integer server cursor supported without rounding")
        check(try SongCommentMapping.decode(F.root([], cursor: true)).cursor == nil, "boolean cursor rejected")
        print("PASS: \(count) synthetic song-comment mapping checks")
    }
}
