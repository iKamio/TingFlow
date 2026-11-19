import Foundation
import CoreFoundation

struct NeteaseRecentSong: Identifiable, Hashable {
    let song: Song
    /// Unix milliseconds, retained losslessly; not a duration or ranking score.
    let playTime: Int64
    let resourceID: String?
    var id: String { song.id } // parser keeps the first occurrence of each song
    var playedAt: Date { Date(timeIntervalSince1970: Double(playTime) / 1000) }
}

/// Pure protocol construction/parsing. No consent, credentials, encryption or IO.
/// The caller owns consent (default off), account matching and original-source eligibility.
enum NeteaseHistoryPolicy {
    static let recentRoute = "/api/play-record/song/list"
    static let weblogRoute = "/api/feedback/weblog"
    static let maximumRows = 500
    enum Failure: Error, Equatable { case invalidInput, malformedResponse, tooManyRows }
    enum Action: String { case startplay, play }
    // Only this end value is established by the audited reference. Never infer
    // it for stop/skip/error/logout. nil omits end; acceptance is not guaranteed.
    enum EndReason: String { case naturalEnd = "playend" }

    /// RecentPlay DTO was not present locally. Uses the documented Enhanced
    /// record_recent_song shape: data.list[].{data: song, playTime, resourceId}.
    /// Preserves server order; NOT /v1/play/record's listening-count ranking.
    /// data:null and list:[] are explicit empty results. Bad envelopes, excess
    /// rows and nonempty lists with no valid song records throw, not fake empty.
    /// Mixed malformed/non-song entries are skipped; duplicate songs keep first.
    static func recentSongs(_ body: [String: Any], scope: String) throws -> [NeteaseRecentSong] {
        guard scope.hasPrefix("netease:"), NeteaseMapping.id(String(scope.dropFirst(8))) != nil else { throw Failure.invalidInput }
        if let code = body["code"] {
            guard integer(code) == 200 else { throw Failure.malformedResponse }
        }
        if body["data"] is NSNull { return [] }
        guard let data = body["data"] as? [String: Any],
              let rows = data["list"] as? [Any] else { throw Failure.malformedResponse }
        guard rows.count <= maximumRows else { throw Failure.tooManyRows }
        var seen = Set<String>()
        var result: [NeteaseRecentSong] = []
        for value in rows {
            guard let row = value as? [String: Any],
                  let rawSong = row["data"] as? [String: Any],
                  let song = NeteaseMapping.song(rawSong, scope: scope),
                  let time = integer(row["playTime"]), time > 0, time <= 4_102_444_800_000 else { continue }
            // resourceId may be absent; never fabricate a missing song from it.
            let rawResource = row["resourceId"]
            let resource = NeteaseMapping.id(rawResource)
            if let rawResource, !(rawResource is NSNull), resource != song.platformID { continue }
            guard song.duration.isFinite, seen.insert(song.platformID).inserted else { continue }
            result.append(NeteaseRecentSong(song: song, playTime: time, resourceID: resource))
        }
        guard rows.isEmpty || !result.isEmpty else { throw Failure.malformedResponse }
        return result
    }

    /// One action per logs JSON array. seconds is observed time, never duration.
    /// Unknown source is the protocol's 0, not a fabricated playlist ID.
    /// No end reason is added implicitly. A caller lacking a verified reason
    /// may omit it (service acceptance unknown) or choose not to submit a finish.
    static func logs(action: Action, songID: String, seconds: Double = 0,
                     sourceID: String? = nil, endReason: EndReason? = nil) throws -> [String: String] {
        guard NeteaseMapping.id(songID) == songID, let numericID = UInt64(songID),
              seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw Failure.invalidInput }
        let source = sourceID ?? "0"
        guard source == "0" || NeteaseMapping.id(source) == source else { throw Failure.invalidInput }
        var json: [String: Any] = ["id": NSNumber(value: numericID), "type": "song",
            "mainsite": "1", "mainsiteWeb": "1", "content": "id=\(source)"]
        switch action {
        case .startplay:
            guard seconds == 0, endReason == nil else { throw Failure.invalidInput }
        case .play:
            guard seconds >= 1 else { throw Failure.invalidInput }
            json["time"] = Int(seconds.rounded(.down))
            json["download"] = 0
            json["sourceId"] = source
            json["source"] = "list"
            json["wifi"] = 0
            if let endReason { json["end"] = endReason.rawValue }
        }
        let data = try JSONSerialization.data(withJSONObject: [["action": action.rawValue, "json": json]], options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else { throw Failure.invalidInput }
        return ["logs": value]
    }

    private static func integer(_ value: Any?) -> Int64? {
        let text: String
        if let value = value as? String { text = value }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            text = value.stringValue
        } else { return nil }
        guard !text.isEmpty, text.count <= 19,
              text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }
}
