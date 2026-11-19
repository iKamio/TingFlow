import Foundation

@main struct SourceMatchChecks {
    static func main() {
        let song = Song(platform: .netease, platformID: "100", title: "晴天", artist: "周杰伦", album: "", duration: 269)
        func candidate(_ title: String = "晴天", _ artist: String = "周杰伦", _ seconds: Double = 269, _ id: String = "1") -> Song {
            Song(platform: .kugou, platformID: id, title: title, artist: artist, album: "", duration: seconds, hash: "fixture")
        }
        precondition(SourceMatchPolicy.matches(song, candidate()), "same metadata accepted")
        precondition(SourceMatchPolicy.matches(song, candidate(" 晴天 ", "周杰伦", 273)), "bounded duration and whitespace")
        precondition(!SourceMatchPolicy.matches(song, candidate("晴天", "另一歌手")), "wrong artist rejected")
        precondition(!SourceMatchPolicy.matches(song, candidate("晴天 Live")), "live version rejected")
        precondition(!SourceMatchPolicy.matches(song, candidate("晴天 (Remix)")), "remix rejected")
        precondition(!SourceMatchPolicy.matches(song, candidate("晴天", "周杰伦", 0)), "missing duration rejected")
        precondition(!SourceMatchPolicy.matches(song, candidate("晴天", "周杰伦", 280)), "wrong duration rejected")
        precondition(SourceMatchPolicy.uniqueMatch(song, candidates: [candidate(), candidate()]) != nil, "same ID deduplicated")
        precondition(SourceMatchPolicy.uniqueMatch(song, candidates: [candidate(), candidate("晴天", "周杰伦", 269, "2")]) == nil, "ambiguous edition rejected")
        precondition(SourceMatchPolicy.uniqueMatch(song, candidates: [candidate("别的歌")]) == nil, "no substitute song")
        print("PASS: 10 strict cross-source metadata matching checks; no audio requests")
    }
}
