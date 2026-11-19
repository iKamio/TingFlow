// macOS/Xcode offline policy tests; no network, file picker or user audio.
import Foundation
@main struct SourceChecks {
    static func main() throws {
        let source = UserSource(id: UUID(), sha256: String(repeating: "a", count: 64), name: "fixture",
            version: "1", author: "test", description: "")
        precondition((try? SourceURLPolicy.hosts("api.example.invalid; cdn.example.invalid"))?.count == 2, "host allowlist")
        for host in ["localhost", "printer.local", "127.0.0.1", "::1", "*.example.invalid", "https://host.invalid/path", "bad host.invalid"] {
            precondition((try? SourceURLPolicy.host(host)) == nil, "reject unsafe host")
        }
        precondition((try? SourceURLPolicy.url("https://api.example.invalid/a", allowed: ["api.example.invalid"])) != nil, "authorized HTTPS")
        for raw in ["http://api.example.invalid/a", "https://evil.example.invalid/a", "https://api.example.invalid:8443/a", "https://u@api.example.invalid/a"] {
            precondition((try? SourceURLPolicy.url(raw, allowed: ["api.example.invalid"])) == nil, "reject unauthorized URL")
        }
        var song = Song(platform: .kugou, platformID: "12345", title: "Same", artist: "Artist A / Artist B", album: "Album", duration: 99,
                        hash: "h128", highQualityHash: "h320", losslessHash: nil)
        let info = SourceLegacyInfo.make(song)
        precondition(info["source"] as? String == "kg" && info["songmid"] as? String == "12345", "legacy platform identity")
        precondition(info["interval"] as? String == "01:39", "legacy duration formatting")
        let map = info["_types"] as? [String: Any]
        precondition(map?["128k"] != nil && map?["320k"] != nil && map?["flac"] == nil, "only real quality hashes")
        song.accountScope = "user-scope"
        precondition(SourceLegacyInfo.make(song)["source"] as? String == "kg", "metadata remains isolated from credentials")
        let caps = try SourceCapability.validate(["sources": ["kg": ["type": "music", "actions": ["musicUrl"], "qualitys": ["320k", "ape"]],
                                                              "wy": ["type": "music", "actions": ["pic"], "qualitys": ["flac"]]]])
        precondition(caps["kg"]?.qualitys == ["320k"] && caps["wy"] == nil, "capability intersection")
        precondition(!source.isTrusted && !source.isEnabled, "new source quarantined")
        let standardOnly = SourceCapability(actions: ["musicUrl"], qualitys: ["128k"])
        precondition(standardOnly.compatibleQuality(.lossless) == .standard, "never request unsupported lossless")
        precondition(caps["kg"]?.compatibleQuality(.lossless) == .high && caps["kg"]?.compatibleQuality(.standard) == nil, "highest not exceeding requested quality")
        print("PASS: source URL trust, no-cookie legacy mapping and LX capability policy")
    }
}
