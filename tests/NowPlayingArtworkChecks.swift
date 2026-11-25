// From the source root (macOS; no UIKit/AVAudioSession dependency):
// xcrun swiftc -swift-version 5 app/TingFlow/Playback/NowPlayingArtworkPolicy.swift tests/NowPlayingArtworkChecks.swift -o /tmp/now-playing-artwork-checks
// /tmp/now-playing-artwork-checks
// Offline identity/wiring checks only. Lock screen/Control Center rendering still needs
// real-device verification: play, pause/resume, rapid A-B-A, no-cover track, stop/logout.
import Foundation

@main struct NowPlayingArtworkChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func main() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let next = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let url = URL(string: "https://p1.music.126.net/fixture/cover.jpg")!
        let other = URL(string: "https://p1.music.126.net/fixture/other.jpg")!
        let scopedID = "wy:account-a:123"
        let cover = NowPlayingArtworkIdentity(generation: first, songID: scopedID, url: url)
        check(cover.accepts(generation: first, songID: scopedID, url: url), "current selection accepted")
        check(!cover.accepts(generation: next, songID: scopedID, url: url), "A-B-A / same-song retry rejects old completion")
        check(!cover.accepts(generation: first, songID: "wy:account-b:123", url: url), "account scope isolates identity")
        check(!cover.accepts(generation: first, songID: "kg:account-a:123", url: url), "platform isolates identity")
        check(!cover.accepts(generation: first, songID: scopedID, url: other), "changed cover URL rejects completion")
        check(!cover.accepts(generation: first, songID: nil, url: url), "stopped selection rejects completion")
        check(!cover.accepts(generation: first, songID: scopedID, url: nil), "no-cover selection rejects completion")
        check(cover.belongsTo(songID: scopedID, url: url), "accepted cover remains valid across pause/audio retirement")
        check(!cover.belongsTo(songID: "wy:account-a:456", url: url), "accepted cover cannot leak to another track")
        check(!cover.belongsTo(songID: scopedID, url: other), "accepted cover is URL scoped")
        check(!cover.belongsTo(songID: nil, url: nil), "stop/logout removes metadata identity")

        // Source-contract assertions exercise the actual wiring without importing iOS frameworks.
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        let player = try String(contentsOf: root.appendingPathComponent("app/TingFlow/Playback/PlayerStore.swift"), encoding: .utf8)
        let loader = try String(contentsOf: root.appendingPathComponent("app/TingFlow/UI/ArtworkLoader.swift"), encoding: .utf8)
        func section(_ start: String, _ end: String) -> String {
            guard let a = player.range(of: start), let b = player.range(of: end, range: a.upperBound..<player.endIndex) else {
                preconditionFailure("missing PlayerStore section")
            }
            return String(player[a.upperBound..<b.lowerBound])
        }
        let select = section("private func select(", "private func loadArtwork(")
        let load = section("private func loadArtwork(", "private func attach(")
        let retire = section("private func retire()", "private func fail(")
        let metadata = section("private func publishMetadata()", "private func bind(")
        let refresh = section("private func refresh()", "private func retire()")
        let pause = section("func pause()", "func next()")
        let stop = section("func stop()", "private func rebuildOrder()")
        let clear = select.range(of: "artwork = nil")!
        let publish = select.range(of: "publishMetadata()")!
        check(clear.lowerBound < publish.lowerBound, "clear stale cover before new title/time publication")
        check(player.components(separatedBy: "loadArtwork(for: song, token: token)").count == 2 && select.contains("loadArtwork(for: song, token: token)"), "one artwork start per selection")
        check(!refresh.contains("ArtworkLoader") && !metadata.contains("ArtworkLoader"), "half-second refresh never downloads/decodes")
        check(load.contains("ArtworkLoader.isAllowed(url)") && load.contains("ArtworkLoader.shared.data(url)"), "only shared public allowlisted loader")
        check(load.contains("ArtworkLoader.thumbnail(data)"), "uses existing downsampled decoder")
        check(load.contains("Task.checkCancellation()") && load.contains("identity.accepts(generation: self.generation, songID: self.current?.id, url: self.current?.displayArtworkURL)"), "completion checks cancellation/generation/id/URL")
        check(load.contains("MPMediaItemArtwork(boundsSize: image.size) { [image] _ in image }"), "system callback captures only decoded immutable image")
        check(load.contains("self.publishMetadata()") && !load.contains("self.fail("), "successful image republishes metadata; failure is optional")
        check(metadata.contains("info[MPMediaItemPropertyArtwork] = artwork.value"), "real system artwork property is populated")
        check(metadata.contains("artwork.identity.belongsTo(songID: song.id, url: song.displayArtworkURL)"), "metadata is scoped to current cover")
        check(retire.contains("artworkTask?.cancel()") && !retire.contains("artwork = nil"), "retire cancels pending work but preserves accepted cover on audio error")
        check(!pause.contains("artwork = nil") && !pause.contains("artworkTask?.cancel()"), "pause keeps current/in-flight cover")
        check(stop.contains("artwork = nil") && stop.contains("current = nil"), "stop/logout clears cover and current metadata")
        check(loader.contains("kCGImageSourceThumbnailMaxPixelSize: 700") && loader.contains("data.count >= 4_000_000"), "shared loader retains native pixel/byte bounds")
        print("PASS: Now Playing artwork identity, stale-generation rejection and metadata/loader wiring (not system UI validation)")
    }
}
