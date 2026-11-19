import Foundation

/// macOS standalone, no Store/Client/account/network fixtures required:
/// xcrun swiftc -swift-version 5 app/TingFlow/Netease/NeteasePlaylistLoadController.swift \
///   tests/NeteasePlaylistLoadChecks.swift -o /tmp/playlist-load-checks && /tmp/playlist-load-checks
@main struct NeteasePlaylistLoadChecks {
    typealias Loader = NeteasePlaylistLoadController<Int>
    enum SyntheticError: Error { case failure }
    @MainActor final class Callback {
        var continuations: [CheckedContinuation<[Int], Error>] = []
        // Intentionally ignores task cancellation, like an uncooperative callback API.
        func read() async throws -> [Int] {
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func succeed(_ index: Int, _ items: [Int]) { continuations[index].resume(returning: items) }
        func fail(_ index: Int, _ error: Error) { continuations[index].resume(throwing: error) }
    }
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); checks += 1 }
        let a = Loader.Identity(playlistID: "synthetic-list", accountScope: "synthetic-a", sessionScope: "synthetic-a", signedIn: true)
        let b = Loader.Identity(playlistID: "synthetic-list", accountScope: "synthetic-b", sessionScope: "synthetic-b", signedIn: true)
        let callback = Callback()
        let loader = Loader()
        var current = true
        func start(_ reason: Loader.Failure = .network) {
            loader.load(identity: a, expectedCount: 257, operation: { try await callback.read() },
                        isCurrent: { current }, failure: { _ in reason })
        }
        start()
        await until { callback.continuations.count == 1 }
        check(loader.isLoading && loader.expectedCount == 257, "257-track initial request is explicit")
        let songs = Array(0..<256) + [0]
        callback.succeed(0, songs)
        await until { !loader.isLoading }
        check(loader.phase == .loaded && loader.items == songs, "257 tracks, ordering and duplicates unchanged")

        start()
        await until { callback.continuations.count == 2 }
        check(loader.items == songs, "refresh preserves already fetched songs")
        callback.fail(1, SyntheticError.failure)
        await until { !loader.isLoading }
        check(loader.phase == .failed(.network) && loader.items == songs, "failure preserves old songs and stops spinner")

        start(.rateLimited)
        await until { callback.continuations.count == 3 }
        callback.fail(2, SyntheticError.failure)
        await until { !loader.isLoading }
        loader.appear(identity: a, expectedCount: 257, operation: { preconditionFailure("automatic risk retry") }, isCurrent: { true }, failure: { _ in .other })
        check(loader.phase == .failed(.rateLimited), "appearance never automatically retries risk")

        start()
        await until { callback.continuations.count == 4 }
        loader.cancel()
        check(loader.phase == .cancelled && loader.items == songs, "cancel is immediate without callback acknowledgment")
        loader.appear(identity: a, expectedCount: 257, operation: { preconditionFailure("automatic cancellation retry") }, isCurrent: { true }, failure: { _ in .other })
        check(!loader.isLoading, "reappearance does not restart a cancelled task")
        start()
        await until { callback.continuations.count == 5 }
        callback.succeed(4, [9, 9, 7])
        await until { !loader.isLoading }
        callback.succeed(3, [999])
        await drain()
        check(loader.items == [9, 9, 7] && loader.phase == .loaded, "late cancelled success cannot overwrite retry")

        start()
        await until { callback.continuations.count == 6 }
        loader.setIdentity(b)
        check(loader.items.isEmpty && !loader.isLoading, "account switch clears private songs immediately")
        loader.setIdentity(a)
        callback.succeed(5, [888])
        await drain()
        check(loader.items.isEmpty && loader.phase == .idle, "A-B-A identity transition rejects original A response")

        start()
        await until { callback.continuations.count == 7 }
        current = false
        callback.succeed(6, [123])
        await until { !loader.isLoading }
        check(loader.items.isEmpty && loader.phase == .idle, "completion revalidates identity before UI onChange fires")
        current = true
        start()
        await until { callback.continuations.count == 8 }
        callback.fail(7, CancellationError())
        await until { !loader.isLoading }
        check(loader.phase == .cancelled, "upstream cancellation is terminal, never an endless spinner")

        // A sleeping/uncooperative worker must not keep timeout scope alive as a task group would.
        let stalled = Callback()
        let timed = Loader(deadlineSeconds: 0.03)
        timed.load(identity: a, expectedCount: 257, operation: { try await stalled.read() }, isCurrent: { true }, failure: { _ in .other })
        await until { stalled.continuations.count == 1 }
        await until { timed.phase == .failed(.deadline) }
        check(!timed.isLoading && timed.items.isEmpty, "logical deadline completes while worker remains suspended")
        timed.appear(identity: a, expectedCount: 257, operation: { preconditionFailure("automatic timeout retry") }, isCurrent: { true }, failure: { _ in .other })
        check(timed.phase == .failed(.deadline), "timeout does not automatically retry")
        timed.load(identity: a, expectedCount: 1, operation: { [42] }, isCurrent: { true }, failure: { _ in .other })
        await until { timed.phase == .loaded }
        stalled.succeed(0, [1000])
        await drain()
        check(timed.items == [42] && timed.phase == .loaded, "late timed-out success cannot change newer results")

        // Completion itself enforces the absolute monotonic deadline, even before timer runs.
        var instant: TimeInterval = 10
        let queued = Callback()
        let clocked = Loader(deadlineSeconds: 45, now: { instant })
        clocked.load(identity: a, expectedCount: 257, operation: { try await queued.read() }, isCurrent: { true }, failure: { _ in .other })
        await until { queued.continuations.count == 1 }
        instant += 46
        queued.succeed(0, [77])
        await until { !clocked.isLoading }
        check(clocked.phase == .failed(.deadline) && clocked.items.isEmpty, "late success after suspension cannot beat queued watchdog")

        let privacyCases: [Loader.Failure] = [.deadline, .network, .verification, .rateLimited, .signedOut, .invalidData, .rejected, .other]
        check(privacyCases.allSatisfy { !$0.message.contains("http") && !$0.message.contains("synthetic-") && !$0.message.contains("Cookie") }, "all diagnostics are fixed safe text")
        print("PASS: \(checks) isolated playlist lifecycle/deadline/privacy checks (synthetic callbacks only)")
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("synthetic callback test timed out")
    }
    @MainActor static func drain() async { for _ in 0..<20 { await Task.yield() } }
}
