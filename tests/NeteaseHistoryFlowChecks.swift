import Foundation

@main @MainActor struct NeteaseHistoryFlowChecks {
    static var count = 0
    static func check(_ ok: Bool, _ label: String) { precondition(ok, label); count += 1 }
    static func logs() -> [NeteaseCloudFixture.Record] { NeteaseCloudFixture.requests().filter { $0.path == "/eapi/feedback/weblog" } }
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 { if condition() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
        preconditionFailure("history task did not finish")
    }
    static func main() async throws {
        UserDefaults.standard.removeObject(forKey: "tingflow.netease.history.enabled.7")
        let make: @MainActor () -> NeteaseClient = {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NeteaseCloudFixture.self]
            return NeteaseClient(configuration: config, deviceID: String(repeating: "B", count: 52))
        }
        SecureVault.values["netease.native.weapi.session.v1"] = try JSONSerialization.data(withJSONObject: [
            "version": 1, "userID": "7", "cookies": [["name": "MUSIC_U", "value": "synthetic-history-session"]]])
        let store = NeteaseStore(clientFactory: make)
        await store.refresh()
        check(store.isSignedIn && !store.syncPlaybackHistory, "consent defaults off")
        await store.refreshCloudRecentSongs()
        check(store.cloudRecentSongs.count == 1 && logs().isEmpty, "cloud read does not authorize reporting")
        let song = Song(platform: .netease, platformID: "11", title: "Fixture", artist: "Artist", album: "", duration: 120, accountScope: "netease:7")
        var session = ListeningSession(song: song, scope: "netease:7")
        _ = session.sample(position: 0, monotonic: 0, isPlaying: true)
        _ = session.sample(position: 1, monotonic: 1, isPlaying: true)
        store.enqueueListeningStart(session)
        check(logs().isEmpty, "off means no upload")
        store.setPlaybackHistorySync(true)
        check(store.syncPlaybackHistory && logs().isEmpty, "enabling does not replay history")
        store.enqueueListeningStart(session); store.enqueueListeningStart(session)
        await waitUntil { store.historyUploadMessage?.contains("开始事件已受理") == true }
        check(logs().count == 1, "one start per actual session")
        _ = session.sample(position: 2, monotonic: 2, isPlaying: true)
        let snapshot = session.finish()!
        store.enqueueListeningFinish(snapshot, naturalEnd: false)
        store.enqueueListeningFinish(snapshot, naturalEnd: false)
        await waitUntil { store.historyUploadMessage?.contains("实际听歌时间上报已受理") == true }
        check(logs().count == 2, "one finish, no automatic retries")
        let payload = logs().last!.payload
        let events = try JSONSerialization.jsonObject(with: Data((payload["logs"] as! String).utf8)) as! [[String: Any]]
        let details = events[0]["json"] as! [String: Any]
        check(details["time"] as? Int == 2 && details["end"] == nil, "only two listened seconds; skip not playend")
        let header = payload["header"] as? [String: Any]
        check(header?["os"] as? String == "osx", "reference weblog transport marker only")
        check(logs().allSatisfy(\.safeWire), "encrypted exact API; no external cookies")
        var foreign = ListeningSession(song: song, scope: "netease:8")
        _ = foreign.sample(position: 0, monotonic: 0, isPlaying: true)
        _ = foreign.sample(position: 1, monotonic: 1, isPlaying: true)
        store.enqueueListeningStart(foreign)
        check(logs().count == 2, "no wrong-account upload")
        var another = ListeningSession(song: song, scope: "netease:7")
        _ = another.sample(position: 0, monotonic: 0, isPlaying: true)
        _ = another.sample(position: 1, monotonic: 1, isPlaying: true)
        NeteaseCloudFixture.configure(.timeoutAfterApply)
        store.enqueueListeningStart(another)
        await waitUntil { store.historyUploadMessage?.contains("已暂停且不自动重试") == true }
        let failedCount = logs().count
        store.enqueueListeningStart(another)
        if let snapshot = another.finish() { store.enqueueListeningFinish(snapshot, naturalEnd: true) }
        check(logs().count == failedCount, "ambiguous result pauses, never repeated")
        store.setPlaybackHistorySync(false)
        check(!store.syncPlaybackHistory, "user can stop uploads")
        await store.signOut()
        check(store.cloudRecentSongs.isEmpty && store.historyUploadMessage == nil, "logout removes private history and tasks")
        store.enqueueListeningStart(session)
        check(logs().count == failedCount && SecureVault.values.isEmpty, "no upload after logout")
        UserDefaults.standard.removeObject(forKey: "tingflow.netease.history.enabled.7")
        print("PASS: \(count) cloud-history consent, actual sessions, encrypted events, deduplication and logout checks")
    }
}
