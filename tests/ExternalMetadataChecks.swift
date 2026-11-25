import Foundation

@main struct ExternalMetadataChecks {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
        let song = Song(platform: .subsonic, platformID: "private-server-id", title: "晴天 & A+B?", artist: "周杰伦/Artist", album: "Album", duration: 123, accountScope: "private-scope")
        let url = song.displayArtworkURL!
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        check(parts.host == "api.lrc.cx" && parts.path == "/cover", "fixed cover origin/path")
        check(parts.queryItems?.count == 2, "only two fields")
        check(parts.queryItems?.first(where: { $0.name == "title" })?.value == song.title, "title round-trip with query metacharacters")
        check(parts.queryItems?.first(where: { $0.name == "artist" })?.value == song.artist, "artist round-trip")
        check(!url.absoluteString.contains("private-server") && !url.absoluteString.contains("private-scope"), "no private IDs or account scope")
        check(song.metadataURL("lyrics")?.path == "/lyrics", "correct plural lyrics endpoint")
        check(song.metadataURL("evil") == nil, "no arbitrary metadata routes")
        var missing = song; missing.artist = " "
        check(missing.displayArtworkURL == nil, "missing artist does not issue broad ambiguous request")
        missing = song; missing.title = "A\nCookie:secret"
        check(missing.metadataURL("lyrics") == nil, "reject controls")
        missing = song; missing.artist = String(repeating: "a", count: 513)
        check(missing.displayArtworkURL == nil, "input size bound")
        var online = song; online.artworkURL = URL(string: "https://p1.music.126.net/original.jpg")!
        check(online.displayArtworkURL == online.artworkURL, "original artwork wins")
        let encoded = String(decoding: try JSONEncoder().encode(song), as: UTF8.self)
        check(!encoded.contains("api.lrc.cx") && !encoded.contains("displayArtworkURL"), "external URL is derived not persisted")
        let lrc = try ExternalMetadata.decode(Data("\u{feff}[00:01.250]Fixture line\n[00:02.500]Next".utf8))
        check(LRCParser.parse(lrc).count == 2 && LRCParser.parse(lrc)[0].time == 1.25, "real UTF8 millisecond LRC")
        let plain = try ExternalMetadata.decode(Data("Plain lyric line".utf8))
        check(plain == "Plain lyric line", "plain lyrics supported")
        for invalid in ["", "<html>failed</html>", "{\"error\":true}", "not found"] {
            do { _ = try ExternalMetadata.decode(Data(invalid.utf8)); preconditionFailure("must reject non-lyric response") }
            catch { count += 1 }
        }
        do { _ = try ExternalMetadata.decode(Data(repeating: 65, count: 512001)); preconditionFailure("size bound") }
        catch { count += 1 }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        let player = try source("app/TingFlow/Playback/PlayerStore.swift")
        let view = try source("app/TingFlow/UI/NowPlayingView.swift")
        let loader = try source("app/TingFlow/UI/ArtworkLoader.swift")
        check(player.contains("song.displayArtworkURL") && player.contains("self.current?.displayArtworkURL"), "system artwork uses derived URL with stale guard")
        check(view.contains("ExternalMetadata.shared.lyrics(for: song)") && view.contains("lyricGeneration == token"), "server lyrics wired with generation guard")
        check(loader.contains("mzstatic.com") && loader.contains("url.path == \"/cover\""), "actual cover redirect allowed without arbitrary metadata routes")
        check(loader.contains("httpCookieStorage = nil") && loader.contains("urlCredentialStorage = nil"), "artwork transport has no platform credentials")
        print("PASS: \(count) external metadata policy, parsing and source-wiring checks (no real-account or device assertion)")
    }
}
