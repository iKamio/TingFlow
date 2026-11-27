import Foundation

// Stand-in only for this standalone executable. Any accidental fallback fails;
// no production CatalogClient, URLSession, account or network is linked.
final class CatalogClient {
    func search(_ query: String, platform: MusicPlatform) async throws -> [Song] {
        preconditionFailure("synthetic search must use an injected loader")
    }
}

@main @MainActor struct SearchStoreChecks {
    @MainActor final class Gate {
        private(set) var calls: [(String, MusicPlatform)] = []
        private var continuations: [CheckedContinuation<[Song], Error>] = []
        func read(_ query: String, _ platform: MusicPlatform) async throws -> [Song] {
            calls.append((query, platform))
            // Deliberately non-cooperative, to exercise generation isolation.
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func finish(_ index: Int, _ songs: [Song]) { continuations[index].resume(returning: songs) }
        func fail(_ index: Int) { continuations[index].resume(throwing: MusicError.invalidResponse) }
    }
    static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("synthetic search did not reach expected state")
    }
    static func row(_ id: String, _ platform: MusicPlatform = .netease) -> Song {
        Song(platform: platform, platformID: id, title: "same title", artist: "same artist", album: "", duration: 1)
    }
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let store = SearchStore(), gate = Gate()
        store.catalogSearch = { query, platform in try await gate.read(query, platform) }
        store.query = "old"; store.search(platforms: [.netease])
        try await until { gate.calls.count == 1 }
        store.query = "  new  "; store.search(platforms: [.kugou])
        try await until { gate.calls.count == 2 }
        gate.finish(1, [row("new", .kugou)])
        try await until { !store.isSearching }
        check(store.submittedQuery == "new" && store.results.map(\.id) == [row("new", .kugou).id], "new query and platform publish first")
        gate.fail(0)
        // Complete another request before checking old callbacks have no effects.
        store.query = "final"; store.search(platforms: [.netease])
        try await until { gate.calls.count == 3 }
        gate.finish(2, [row("final")])
        try await until { !store.isSearching }
        check(store.failures.isEmpty && store.results.map(\.platformID) == ["final"], "late old failure cannot replace a new search")

        store.query = "cleared"; store.search(platforms: [.netease])
        try await until { gate.calls.count == 4 }
        store.clear(); gate.finish(3, [row("stale")])
        for _ in 0..<10 { await Task.yield() }
        check(store.results.isEmpty && store.failures.isEmpty && store.pending.isEmpty && !store.isSearching, "clear invalidates a non-cooperative result")

        store.query = "partial"; store.search(platforms: [.netease, .kugou])
        try await until { gate.calls.count == 6 }
        let neteaseIndex = (4..<6).first { gate.calls[$0].1 == .netease }!
        let kugouIndex = (4..<6).first { gate.calls[$0].1 == .kugou }!
        gate.finish(neteaseIndex, [row("1"), row("1")])
        try await until { store.results.count == 1 }
        check(store.isSearching && store.pending == [.kugou], "one completed bucket remains visible while another is pending")
        gate.fail(kugouIndex)
        try await until { !store.isSearching }
        check(store.results.count == 1 && store.failures[.kugou] != nil, "failed provider preserves successful deduplicated bucket")
        store.search(platforms: [.kugou])
        try await until { gate.calls.count == 7 }
        gate.finish(6, [row("1", .kugou)])
        try await until { !store.isSearching }
        check(store.failures.isEmpty && store.results.first?.platform == .kugou, "explicit retry resets failure and respects selected provider")
        store.query = "bad\nquery"; store.search()
        check(store.submittedQuery.isEmpty && store.results.isEmpty && !store.isSearching && gate.calls.count == 7, "invalid query clears without dispatch")
        print("PASS: \(checks) synthetic search-store race/retry checks")
    }
}
