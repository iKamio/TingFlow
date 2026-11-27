import Foundation

@main struct SearchPolicyChecks {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); count += 1 }
        let first = Song(platform: .netease, platformID: "1", title: "one", artist: "a", album: "x", duration: 1)
        let second = Song(platform: .netease, platformID: "2", title: "two", artist: "a", album: "x", duration: 2)
        let kg = Song(platform: .kugou, platformID: "3", title: "three", artist: "b", album: "y", duration: 3)
        let emby = Song(platform: .emby, platformID: "secret", title: "private", artist: "server", album: "", duration: 1, accountScope: "scope")
        check(SearchAggregationPolicy.query("  周杰伦  ") == "周杰伦", "trim query")
        check(SearchAggregationPolicy.query("\n\t") == nil, "empty query")
        check(SearchAggregationPolicy.query("bad\nheader") == nil, "control rejected")
        check(SearchAggregationPolicy.query(String(repeating: "a", count: 513)) == nil, "query bound")
        check(SearchAggregationPolicy.matches("  周杰伦 \n", submitted: "周杰伦"), "trimmed submission remains visible")
        check(!SearchAggregationPolicy.matches("周杰伦新", submitted: "周杰伦"), "changed query hides old results")
        check(!SearchAggregationPolicy.matches("  ", submitted: ""), "empty input is not a submitted search")
        check(!SearchAggregationPolicy.matches("bad\nquery", submitted: "badquery"), "invalid query cannot match old results")
        check(SearchAggregationPolicy.platforms(emby: false, subsonic: false) == [.netease, .kugou], "unconnected servers omitted")
        check(SearchAggregationPolicy.platforms(emby: true, subsonic: true) == [.netease, .kugou, .emby, .subsonic], "connected platforms appended")
        let mixed = SearchAggregationPolicy.merged([.netease: [first, second], .kugou: [kg]], platforms: [.netease, .kugou])
        check(mixed.map(\.id) == [first.id, kg.id, second.id], "stable interleave and dedup")
        check(SearchAggregationPolicy.merged([.netease: [first, kg]], platforms: [.netease]) == [first], "mismatched bucket cannot inject platform")
        check(SearchAggregationPolicy.merged([.emby: [emby]], platforms: [.netease, .kugou]).isEmpty, "private service never leaks into catalog-only aggregation")
        let alternative = Song(platform: .kugou, platformID: "1", title: first.title, artist: first.artist, album: first.album, duration: first.duration)
        var scopedAlternative = emby
        scopedAlternative.accountScope = "other-scope"
        let candidates = SearchAggregationPolicy.merged([.netease: [first, first, second], .kugou: [alternative], .emby: [emby, scopedAlternative]], platforms: [.netease, .kugou, .emby])
        check(candidates.map(\.id) == [first.id, alternative.id, emby.id, scopedAlternative.id, second.id], "same metadata retains every platform and account candidate while exact IDs deduplicate")
        let missing = Song(platform: .netease, platformID: "11", title: "cover", artist: "a", album: "x", duration: 1)
        let ids = CatalogArtworkMapping.idsNeedingArtwork([first, missing, missing, kg, emby])
        check(ids == ["1", "11"], "only exact public Netease identifiers are enriched")
        let url = "https://p1.music.126.net/cover.jpg"
        let enriched = CatalogArtworkMapping.merging([missing, first, kg], details: [["id": "11", "al": ["picUrl": url]], ["id": "12", "al": ["picUrl": url]]], requested: ["11"])
        check(enriched[0].artworkURL?.absoluteString == url, "requested exact ID receives real catalog image")
        check(enriched[1].artworkURL == nil && enriched[2].artworkURL == nil, "no wrong ID or cross-platform image")
        check(CatalogArtworkMapping.artwork("http://evil.invalid/x") == nil, "untrusted cover host refused")
        print("PASS: \(count) search aggregation and exact-cover checks (synthetic offline only)")
    }
}
