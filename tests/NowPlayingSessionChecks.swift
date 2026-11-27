// Offline wiring checks only; a signed iPhone must verify system media-card taps.
import Foundation

@main struct NowPlayingSessionChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        let player = try String(contentsOf: root.appendingPathComponent("app/TingFlow/Playback/PlayerStore.swift"), encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("app/TingFlow/ContentView.swift"), encoding: .utf8)
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
        }
        check(player.contains("MPNowPlayingInfoCenter.default()"), "metadata belongs to the app-level center")
        check(player.contains("MPRemoteCommandCenter.shared()"), "commands belong to the same app-level center")
        check(!player.contains("MPNowPlayingSession("), "no competing per-player Now Playing session")
        check(player.contains("beginReceivingRemoteControlEvents()") && player.contains("endReceivingRemoteControlEvents()"), "remote event lifecycle is balanced at stop")
        check(player.contains("nowPlayingInfoCenter.nowPlayingInfo = info"), "track metadata is published")
        check(player.contains("nowPlayingInfoCenter.nowPlayingInfo = nil"), "stop clears metadata")
        check(player.contains("restoreSystemPlaybackOwnership()") && content.contains("player.restoreSystemPlaybackOwnership()"), "foreground refresh restores app media ownership")
        check(content.contains("url.host == \"now-playing\""), "explicit playback route is handled")
        print("PASS: app-level Now Playing ownership and foreground routing (not OS tap validation)")
    }
}
