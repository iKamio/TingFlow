import Foundation

@main @MainActor struct SongCommentStoreChecks {
    static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("synthetic callback did not reach expected state")
    }
    static func main() async throws {
        typealias F = SongCommentFixture
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let model = SongCommentStore()
        var calls: [(CommentSort, Int, String?)] = []
        await model.open(songID: "9", contextID: "anonymous", sort: .hot) { sort, page, cursor in
            calls.append((sort, page, cursor))
            return F.page(page == 1 ? ["1", "2"] : ["2", "3"], more: page == 1, total: 12)
        }
        check(calls.count == 1 && model.state == .ready && model.total == 12, "one explicit first request, no crawling")
        await model.loadNext()
        check(model.comments.map(\.id) == ["1", "2", "3"] && model.state == .end, "cross-page duplicate preserves first row and order")
        await model.loadNext()
        check(calls.count == 2 && calls[1].1 == 2, "end never fetches another page")

        await model.open(songID: "9", contextID: "anonymous", sort: .latest) { _, page, cursor in
            check(cursor == (page == 1 ? nil : "1000"), "latest forwards corresponding response cursor")
            return F.page(["\(page)"], more: page == 1, cursor: page == 1 ? "1000" : nil)
        }
        check(model.total == nil && model.comments.count == 1 && model.sort == .latest, "sort resets total/items/page")
        await model.loadNext()
        check(model.state == .end && model.nextPage == 3, "latest page committed")

        let badCursors: [String?] = [nil, "", "0", "bad\n", String(repeating: "x", count: 257)]
        for invalidCursor in badCursors {
            await model.open(songID: "9", contextID: "a", sort: .latest) { _, _, _ in F.page(["1"], cursor: invalidCursor) }
            if case .limited = model.state { check(!model.canLoadMore, "missing/malformed cursor stops pagination") }
            else { preconditionFailure("invalid cursor must not permit infinite latest requests") }
        }
        await model.open(songID: "9", contextID: "a", sort: .latest) { _, page, _ in F.page(["\(page)"], cursor: page == 2 ? "B" : "A") }
        await model.loadNext(); await model.loadNext()
        if case .limited = model.state { check(model.nextPage == 4, "A-B-A cursor cycle detected") }
        else { preconditionFailure("cursor cycle") }
        await model.open(songID: "9", contextID: "a", sort: .hot) { _, _, _ in F.page(["1"]) }
        await model.loadNext()
        if case .limited = model.state { check(model.comments.count == 1, "duplicate-only page stops no-progress loop") }
        else { preconditionFailure("duplicate-only page") }
        await model.open(songID: "9", contextID: "a", sort: .hot) { _, _, _ in F.page([], more: true) }
        if case .limited = model.state { check(model.comments.isEmpty, "empty hasMore is incomplete, not no-comments") }
        else { preconditionFailure("empty hasMore") }
        await model.open(songID: "9", contextID: "a", sort: .hot) { _, _, _ in F.page([], more: false, total: 0) }
        check(model.state == .empty && model.total == 0, "genuine server empty + zero total")

        var attempts = 0
        await model.open(songID: "9", contextID: "a", sort: .hot) { _, page, _ in
            attempts += 1
            if attempts == 2 { throw NeteaseError.rateLimited }
            return F.page(["\(page)"], more: page == 1, total: page == 1 ? 99 : nil)
        }
        await model.loadNext()
        check(model.errorMessage != nil && model.comments.count == 1 && model.nextPage == 2, "failure retains existing page and retry position")
        check(attempts == 2, "rate limit never automatically retried")
        await model.loadNext()
        check(model.state == .end && model.comments.map(\.id) == ["1", "2"] && model.total == 99, "explicit retry succeeds without duplicate or invented count")

        var limitedCalls = 0
        await model.open(songID: "9", contextID: "a", sort: .hot) { _, page, _ in limitedCalls += 1; return F.page(["\(page)"]) }
        for _ in 0..<55 { await model.loadNext() }
        check(limitedCalls == 50 && !model.canLoadMore, "hard fifty-page cap without auto crawling")

        let gate = F.Gate()
        let old = Task { await model.open(songID: "9", contextID: "account7-epoch1", sort: .hot, loader: gate.read) }
        try await until { gate.calls.count == 1 }
        let concurrent = Task { await model.loadNext() }
        await concurrent.value
        check(gate.calls.count == 1, "concurrent load-more tap cannot duplicate an in-flight request")
        let fresh = Task { await model.open(songID: "9", contextID: "account7-epoch2", sort: .latest, loader: gate.read) }
        try await until { gate.calls.count == 2 }
        gate.finish(1, F.page(["22"], more: false, total: 1)); await fresh.value
        gate.finish(0, F.page(["11"], more: true, total: 500)); await old.value
        check(model.comments.map(\.id) == ["22"] && model.total == 1 && model.sort == .latest, "same account re-login/sort change rejects stale callback and total")
        let songOld = Task { await model.open(songID: "old-song", contextID: "account8", sort: .hot, loader: gate.read) }
        try await until { gate.calls.count == 3 }
        let songNew = Task { await model.open(songID: "new-song", contextID: "account8", sort: .hot, loader: gate.read) }
        try await until { gate.calls.count == 4 }
        gate.finish(3, F.page(["44"], more: false)); await songNew.value
        gate.finish(2, F.page(["33"], more: false)); await songOld.value
        check(model.comments.map(\.id) == ["44"], "song navigation rejects late previous-song page")
        let navigating = Task { await model.open(songID: "9", contextID: "account8", sort: .hot, loader: gate.read) }
        try await until { gate.calls.count == 5 }
        model.cancel(clear: true)
        check(model.comments.isEmpty && model.total == nil && !model.isLoading, "navigation cancels immediately and clears account content")
        gate.finish(4, F.page(["55"], more: false)); await navigating.value
        check(model.comments.isEmpty && model.state == .idle, "late canceled callback cannot resurrect content")

        let background = SongCommentStore(), backgroundGate = F.Gate()
        let opening = Task { await background.open(songID: "9", contextID: "account8", sort: .latest, loader: backgroundGate.read) }
        try await until { backgroundGate.calls.count == 1 }
        backgroundGate.finish(0, F.page(["1"], cursor: "1000", total: 3)); await opening.value
        let paging = Task { await background.loadNext() }
        try await until { backgroundGate.calls.count == 2 }
        background.cancel()
        check(background.state == .ready && background.nextPage == 2 && background.cursor == "1000", "background cancel retains committed page and cursor")
        let resumed = Task { await background.loadNext() }
        try await until { backgroundGate.calls.count == 3 }
        check(backgroundGate.calls[2].1 == 2 && backgroundGate.calls[2].2 == "1000", "explicit resume retries the uncommitted page")
        backgroundGate.finish(2, F.page(["1", "3"], more: false, total: 3)); await resumed.value
        backgroundGate.fail(1, NeteaseError.network); await paging.value
        check(background.comments.map(\.id) == ["1", "3"] && background.total == 3 && background.state == .end, "late cancelled page failure cannot overwrite resumed results")

        let timed = SongCommentStore(deadlineNanoseconds: 100_000_000)
        let timeoutGate = F.Gate()
        let hung = Task { await timed.open(songID: "9", contextID: "a", sort: .hot, loader: timeoutGate.read) }
        try await until { timeoutGate.calls.count == 1 }
        try await until { timed.errorMessage != nil }
        check(!timed.isLoading && timed.canLoadMore, "deadline stops spinner even if callback ignores cancellation")
        let retry = Task { await timed.loadNext() }
        try await until { timeoutGate.calls.count == 2 }
        timeoutGate.finish(1, F.page(["2"], more: false)); await retry.value
        timeoutGate.finish(0, F.page(["1"], more: false)); await hung.value
        check(timed.comments.map(\.id) == ["2"] && timed.state == .end, "late timed-out result cannot overwrite retry")
        print("PASS: \(checks) synthetic song-comment paging/lifecycle checks")
    }
}
