// Offline wiring regressions only. The Release build compiles the iOS APIs.
// A signed, physical-device check is still required for Lock Screen / Control Center
// app-name or cover taps, including pause/resume, crossfade and another media app.
import Foundation

@main struct NowPlayingSessionChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        let player = try String(contentsOf: root.appendingPathComponent("app/TingFlow/Playback/PlayerStore.swift"), encoding: .utf8)
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
        }
        func section(_ start: String, _ end: String) -> String {
            guard let a = player.range(of: start), let b = player.range(of: end, range: a.upperBound..<player.endIndex) else {
                preconditionFailure("missing PlayerStore section: \(start)")
            }
            return String(player[a.upperBound..<b.lowerBound])
        }
        check(player.contains("private let nowPlayingSession: MPNowPlayingSession"), "session lives as long as PlayerStore")
        check(player.contains("nowPlayingSession = MPNowPlayingSession(players: [anchor])"), "anchor belongs to the session from initialization")
        check(player.contains("nowPlayingSession.automaticallyPublishesNowPlayingInfo = false"), "explicit track metadata has one publisher")
        check(!player.contains("MPNowPlayingInfoCenter.default()") && !player.contains("MPRemoteCommandCenter.shared()"), "metadata and controls never use a different global session")
        let prepare = section("private func prepareTransition(", "private func transitionTicketIsCurrent")
        check(prepare.range(of: "addNowPlayingPlayer(deck.player)")!.lowerBound < prepare.range(of: "await deck.probeHead")!.lowerBound,
              "incoming player is registered before any audible/probe playback")
        let cleanup = prepare.range(of: "if let candidate { removeNowPlayingPlayer(candidate.player) }")
        check(cleanup != nil && cleanup!.lowerBound < prepare.range(of: "try Task.checkCancellation()")!.lowerBound,
              "every failed/stale preparation exit removes its session player in defer")
        check(prepare.contains("candidate = nil"), "prepared incoming player remains registered")
        let cancel = section("private func cancelTransition(", "private func updateTransition()")
        check(cancel.contains("removeNowPlayingPlayer(cancelledDeck.player); cancelledDeck.dispose()"), "cancelled pending deck leaves session")
        let promote = section("private func promoteIncoming(", "private func stopFadeTimer()")
        check(promote.contains("activeDeck = incoming") && promote.contains("removeNowPlayingPlayer(oldDeck.player); oldDeck.dispose()"),
              "promotion retains incoming membership and removes retired deck")
        let retire = section("private func retire()", "private func fail(")
        check(retire.contains("removeNowPlayingPlayer(oldDeck.player); oldDeck.dispose()"), "stop/error/reselection removes retired active deck")
        let membership = section("private func addNowPlayingPlayer(", "private func resume()")
        check(membership.contains("$0 === player") && membership.contains("player !== anchorPlayer"), "membership is identity based and preserves the session anchor")
        check(membership.contains("guard !nowPlayingSession.isActive else { return }") && membership.contains("becomeActiveIfPossible(completion: nil)"),
              "inactive session is explicitly activated without replacing it")
        let activate = section("private func activate()", "private func addNowPlayingPlayer(")
        check(activate.range(of: "try audio.setActive(true)")!.lowerBound < activate.range(of: "activateNowPlayingSession()")!.lowerBound,
              "audio session is activated before claiming Now Playing")
        let metadata = section("private func publishMetadata()", "private func bind(")
        check(metadata.contains("let center = nowPlayingSession.remoteCommandCenter") && metadata.contains("nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = info"),
              "metadata and enabled controls share the player session")
        check(metadata.contains("if isPlaying { activateNowPlayingSession() }"), "real playback retries early activation refusal")
        check(metadata.contains("nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = nil"), "stop clears owned metadata")
        let commands = section("private func installCommands()", "    deinit {")
        check(commands.contains("let center = nowPlayingSession.remoteCommandCenter"), "remote handlers belong to the session")
        print("PASS: Now Playing session ownership, player lifecycle and remote-command wiring (not OS tap validation)")
    }
}
