import Foundation

@main struct NeteaseHistoryPolicyChecks {
    static func main() throws {
        var checks = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); checks += 1 }
        let song: [String: Any] = ["id": 11, "name": "Fixture", "ar": [["name": "Artist"]], "dt": 120000]
        let entry: [String: Any] = ["data": song, "playTime": 1700000000123 as Int64, "resourceId": "11"]
        let rows = try NeteaseHistoryPolicy.recentSongs(["code": 200, "data": ["list": [entry, entry]]], scope: "netease:7")
        check(rows.count == 1 && rows[0].song.platformID == "11", "dedup retains first record")
        check(rows[0].playTime == 1700000000123 && rows[0].song.accountScope == "netease:7", "exact milliseconds and account scope")
        check(try NeteaseHistoryPolicy.recentSongs(["data": ["list": []]], scope: "netease:7").isEmpty, "explicit empty")
        var malformed = entry; malformed["resourceId"] = "12"
        do { _ = try NeteaseHistoryPolicy.recentSongs(["data": ["list": [malformed]]], scope: "netease:7"); preconditionFailure("conflicting identity") } catch { checks += 1 }
        malformed = entry; malformed["playTime"] = true
        do { _ = try NeteaseHistoryPolicy.recentSongs(["data": ["list": [malformed]]], scope: "netease:7"); preconditionFailure("boolean timestamp") } catch { checks += 1 }
        do { _ = try NeteaseHistoryPolicy.recentSongs(["data": ["list": [entry]]], scope: "emby:7"); preconditionFailure("foreign scope") } catch { checks += 1 }
        func unpack(_ payload: [String: String]) throws -> [String: Any] {
            let data = Data(payload["logs"]!.utf8)
            return (try JSONSerialization.jsonObject(with: data) as! [[String: Any]])[0]
        }
        let start = try unpack(NeteaseHistoryPolicy.logs(action: .startplay, songID: "11"))
        let startJSON = start["json"] as! [String: Any]
        check(start["action"] as? String == "startplay" && startJSON["time"] == nil && startJSON["end"] == nil, "start event never invents duration")
        let finish = try unpack(NeteaseHistoryPolicy.logs(action: .play, songID: "11", seconds: 2.9))
        let finishJSON = finish["json"] as! [String: Any]
        check(finishJSON["time"] as? Int == 2 && finishJSON["end"] == nil, "skip is not natural playend")
        check(finishJSON["sourceId"] as? String == "0" && finishJSON["id"] as? Int == 11, "unknown source remains zero")
        let natural = try unpack(NeteaseHistoryPolicy.logs(action: .play, songID: "11", seconds: 3, endReason: .naturalEnd))
        check((natural["json"] as? [String: Any])?["end"] as? String == "playend", "only explicit natural end")
        let invalidSeconds: [Double] = [.nan, -.infinity, -1, 0, 0.5, 86401]
        for bad in invalidSeconds {
            do { _ = try NeteaseHistoryPolicy.logs(action: .play, songID: "11", seconds: bad); preconditionFailure("invalid duration") } catch { checks += 1 }
        }
        for id in ["0", "-1", "11?token=secret", "0011"] {
            do { _ = try NeteaseHistoryPolicy.logs(action: .startplay, songID: id); preconditionFailure("invalid ID") } catch { checks += 1 }
        }
        check(!String(describing: finish).contains("Cookie") && !String(describing: finish).contains("https://"), "payload has no credentials or resource locator")
        print("PASS: \(checks) Netease cloud-history parser and truthful duration payload checks")
    }
}
