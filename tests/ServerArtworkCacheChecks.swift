import Foundation

// Standalone macOS; links only Foundation and ServerArtworkCache.swift:
// xcrun swiftc -swift-version 5 -parse-as-library app/TingFlow/Core/ServerArtworkCache.swift \
//   tests/ServerArtworkCacheChecks.swift -o /tmp/server-artwork-cache-checks && /tmp/server-artwork-cache-checks
@main @MainActor struct ServerArtworkCacheChecks {
    typealias Cache = ServerArtworkCache
    enum SyntheticError: Error { case rejected }
    static var checks = 0

    // Explicit callback control; deliberately ignores cancellation like a legacy API.
    @MainActor final class Gate {
        private var pending: [CheckedContinuation<Data?, Error>?] = []
        var calls: Int { pending.count }
        private(set) var returned = 0
        private(set) var cancelledOnReturn = false
        func read() async throws -> Data? {
            defer { returned += 1; cancelledOnReturn = Task.isCancelled }
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func succeed(_ value: Data?, index: Int = 0) {
            guard pending.indices.contains(index), let callback = pending[index] else {
                preconditionFailure("fixture callback unavailable")
            }
            pending[index] = nil
            callback.resume(returning: value)
        }
        func fail(index: Int = 0) {
            guard pending.indices.contains(index), let callback = pending[index] else {
                preconditionFailure("fixture callback unavailable")
            }
            pending[index] = nil
            callback.resume(throwing: SyntheticError.rejected)
        }
    }

    static func expect(_ ok: Bool, _ label: String) {
        precondition(ok, "FAIL: \(label)")
        checks += 1
    }
    static func key(_ id: String, scope: String = "fixture-account-a",
                    revision: String? = nil, pixels: Int = 320) -> Cache.Key {
        Cache.Key(scope: scope, id: id, revision: revision, pixels: pixels)
    }
    static func until(_ ready: @MainActor () -> Bool) async {
        for _ in 0..<20_000 {
            if ready() { return }
            await Task.yield()
        }
        preconditionFailure("controlled fixture did not reach its checkpoint")
    }
    static func settle() async { for _ in 0..<64 { await Task.yield() } }
    static func invalid(_ operation: @MainActor () async throws -> Data?) async {
        do { _ = try await operation(); preconditionFailure("expected invalidData") }
        catch let error as Cache.Failure { expect(error == .invalidData, "fixed safe failure") }
        catch { preconditionFailure("failure was not sanitized") }
    }
    static func cancelled(_ task: Task<Data?, Error>) async {
        do { _ = try await task.value; preconditionFailure("expected CancellationError") }
        catch is CancellationError { expect(true, "caller cancellation is delivered") }
        catch { preconditionFailure("wrong cancellation result") }
    }

    static func main() async throws {
        try await bucketsAndIsolation()
        await keyValidation()
        try await evictionAndTTL()
        try await failuresAndLimits()
        try await singleflight()
        try await clearAndLateCompletion()
        try await waiterCancellation()
        print("PASS: \(checks) offline server artwork cache checks (synthetic data, controlled callbacks)")
    }

    static func bucketsAndIsolation() async throws {
        for requested in [Int.min, -1, 0, 1, 319, 320] {
            expect(Cache.pixels(requested) == 320, "small and negative pixel requests clamp")
        }
        for requested in [321, 699, 700, 701, Int.max] {
            expect(Cache.pixels(requested) == 700, "large and enormous pixel requests clamp")
        }
        expect(key("album", pixels: Int.min) == key("album", pixels: 320), "small keys are canonical")
        expect(key("album", pixels: 321) == key("album", pixels: Int.max), "large keys are canonical")
        expect(Set([key("album", pixels: 1), key("album", pixels: 319), key("album")]).count == 1,
               "Hashable uses bucket, not original dimensions")
        expect(key("album", revision: nil) != key("album", revision: ""), "nil and empty revision remain distinct")

        let cache = Cache()
        var calls = 0
        let original = key("album", revision: "revision-a", pixels: 1)
        let first = try await cache.data(for: original) { calls += 1; return Data([1]) }
        let reused = try await cache.data(for: key("album", revision: "revision-a", pixels: 320)) {
            calls += 1; return Data([99])
        }
        expect(first == Data([1]) && reused == first && calls == 1, "same bucket reuses raw data")
        let separate = [key("album", scope: "fixture-account-b", revision: "revision-a"),
                        key("other-album", revision: "revision-a"), key("album", revision: "revision-b"),
                        key("album", revision: "revision-a", pixels: 700)]
        for variant in separate {
            let value = try await cache.data(for: variant) { calls += 1; return Data([2]) }
            expect(value == Data([2]), "scope/id/revision/dimension isolation")
        }
        expect(calls == 5 && cache.statistics.entries == 5, "four isolation axes miss independently")
        let otherInstance = Cache()
        let isolated = try await otherInstance.data(for: original) { calls += 1; return Data([3]) }
        expect(isolated == Data([3]) && calls == 6, "instances never share artwork")
    }

    static func keyValidation() async {
        let cache = Cache()
        var calls = 0
        let invalidKeys = [key("album", scope: ""), key(""), key("album", scope: "a\nb"),
                           key("a\u{007F}b"), key("album", revision: "a\u{0000}b"),
                           key("album", scope: String(repeating: "a", count: 4_097)),
                           key(String(repeating: "a", count: 2_049)),
                           key("album", revision: String(repeating: "a", count: 513))]
        for invalidKey in invalidKeys {
            await invalid { try await cache.data(for: invalidKey) { calls += 1; return Data([1]) } }
        }
        expect(calls == 0 && cache.statistics.entries == 0 && cache.statistics.flights == 0,
               "invalid keys never invoke or retain a loader")
        let accepted = [Cache.Key(scope: String(repeating: "a", count: 4_096),
                                 id: String(repeating: "b", count: 2_048),
                                 revision: String(repeating: "c", count: 512), pixels: 320),
                        key("album/部分 ?+", scope: "fixture account:/[]?&=", revision: "W/\"version:tag ? + =\""),
                        key("album", revision: "")]
        for validKey in accepted {
            do {
                let value = try await cache.data(for: validKey) { calls += 1; return Data([7]) }
                expect(value == Data([7]), "length boundaries and printable opaque tags accepted")
            } catch { preconditionFailure("valid opaque key rejected") }
        }
        expect(calls == accepted.count, "no URL or secret-field restrictions applied to opaque keys")
    }

    static func evictionAndTTL() async throws {
        let cache = Cache(byteLimit: 6, entryLimit: 3)
        var calls = 0
        _ = try await cache.data(for: key("a")) { calls += 1; return Data([1, 1, 1]) }
        _ = try await cache.data(for: key("b")) { calls += 1; return Data([2, 2, 2]) }
        _ = try await cache.data(for: key("a")) { preconditionFailure("LRU access missed") }
        _ = try await cache.data(for: key("c")) { calls += 1; return Data([3, 3, 3]) }
        expect(cache.statistics.bytes == 6 && cache.statistics.entries == 2, "byte eviction respects budget")
        let a = try await cache.data(for: key("a")) { preconditionFailure("recent a evicted") }
        let c = try await cache.data(for: key("c")) { preconditionFailure("inserted c evicted") }
        expect(a == Data([1, 1, 1]) && c == Data([3, 3, 3]), "access promotes an entry in LRU")
        _ = try await cache.data(for: key("b")) { calls += 1; return Data([9, 9, 9]) }
        expect(calls == 4 && cache.statistics.bytes == 6, "oldest b was evicted, not recent a")

        let negatives = Cache(byteLimit: 10, entryLimit: 2)
        var entryCalls = 0
        _ = try await negatives.data(for: key("a")) { entryCalls += 1; return Data([1]) }
        _ = try await negatives.data(for: key("b")) { entryCalls += 1; return nil }
        _ = try await negatives.data(for: key("b")) { preconditionFailure("negative cache missed") }
        _ = try await negatives.data(for: key("c")) { entryCalls += 1; return nil }
        expect(negatives.statistics.entries == 2 && negatives.statistics.bytes == 0,
               "negative hits promote LRU and nil entries count toward limit")
        _ = try await negatives.data(for: key("a")) { entryCalls += 1; return Data([2, 2]) }
        let missing = try await negatives.data(for: key("c")) { preconditionFailure("recent nil evicted") }
        _ = try await negatives.data(for: key("b")) { entryCalls += 1; return nil }
        expect(missing == nil && entryCalls == 5 && negatives.statistics.entries == 2,
               "both positive and negative entries obey entry LRU")

        var time = Date(timeIntervalSince1970: 1_000)
        let timed = Cache(now: { time })
        var missingCalls = 0
        let absent = key("missing")
        _ = try await timed.data(for: absent) { missingCalls += 1; return nil }
        time = time.addingTimeInterval(59)
        _ = try await timed.data(for: absent) { preconditionFailure("nil TTL ended too early") }
        expect(missingCalls == 1 && timed.statistics.entries == 1, "missing is cached before 60 seconds")
        time = time.addingTimeInterval(1)
        _ = try await timed.data(for: absent) { missingCalls += 1; return nil }
        expect(missingCalls == 2, "nil expires exactly at fake-clock TTL")
        time = time.addingTimeInterval(60)
        let found = try await timed.data(for: absent) { missingCalls += 1; return Data([5]) }
        time = time.addingTimeInterval(10_000)
        let stillFound = try await timed.data(for: absent) { preconditionFailure("positive data expired") }
        expect(found == Data([5]) && stillFound == found && missingCalls == 3,
               "expired nil can become positive; positive data has no negative TTL")
        let noTTL = Cache(missingTTL: 0, now: { time })
        var noTTLCalls = 0
        for _ in 0..<2 { _ = try await noTTL.data(for: absent) { noTTLCalls += 1; return nil } }
        expect(noTTLCalls == 2 && noTTL.statistics.entries == 0, "zero TTL disables negative caching")
    }

    static func failuresAndLimits() async throws {
        let cache = Cache()
        var calls = 0
        for _ in 0..<2 {
            await invalid { try await cache.data(for: key("error")) { calls += 1; throw SyntheticError.rejected } }
        }
        expect(calls == 2 && cache.statistics.entries == 0 && cache.statistics.flights == 0,
               "ordinary failures never become sticky or negative entries")
        let recovered = try await cache.data(for: key("error")) { calls += 1; return Data([1]) }
        _ = try await cache.data(for: key("error")) { preconditionFailure("successful retry not cached") }
        expect(recovered == Data([1]) && calls == 3, "ordinary failure permits a later successful retry")

        let cancelledCache = Cache()
        var cancellationCalls = 0
        let upstream = Task { @MainActor in
            try await cancelledCache.data(for: key("upstream")) {
                cancellationCalls += 1; throw CancellationError()
            }
        }
        await cancelled(upstream)
        _ = try await cancelledCache.data(for: key("upstream")) { cancellationCalls += 1; return Data([2]) }
        expect(cancellationCalls == 2, "upstream cancellation is not cached")

        let sizes = Cache()
        var invalidCalls = 0
        for _ in 0..<2 {
            await invalid { try await sizes.data(for: key("empty")) { invalidCalls += 1; return Data() } }
        }
        await invalid {
            try await sizes.data(for: key("oversized")) {
                invalidCalls += 1; return Data(repeating: 1, count: 4_000_001)
            }
        }
        expect(invalidCalls == 3 && sizes.statistics.entries == 0 && sizes.statistics.bytes == 0,
               "empty and oversized data are rejected without caching")
        let maximum = Data(repeating: 7, count: 4_000_000)
        let accepted = try await sizes.data(for: key("maximum")) { maximum }
        _ = try await sizes.data(for: key("maximum")) { preconditionFailure("maximum datum missed") }
        expect(accepted?.count == 4_000_000 && sizes.statistics.bytes == 4_000_000,
               "inclusive 4,000,000-byte datum bound")

        let small = Cache(byteLimit: 2)
        var largeForBudgetCalls = 0
        for _ in 0..<2 {
            let value = try await small.data(for: key("uncached")) {
                largeForBudgetCalls += 1; return Data([1, 2, 3])
            }
            expect(value == Data([1, 2, 3]), "valid datum larger than DI budget is returned uncached")
        }
        expect(largeForBudgetCalls == 2 && small.statistics.bytes == 0 && small.statistics.entries == 0,
               "small DI byte budgets cannot be overrun")
        let capped = Cache(byteLimit: Int.max, entryLimit: Int.max)
        for i in 0..<4 { _ = try await capped.data(for: key("large-\(i)")) { maximum } }
        expect(capped.statistics.bytes == 12_000_000 && capped.statistics.entries == 3,
               "DI cannot increase the hard 12 MB limit")
        let cappedEntries = Cache(entryLimit: Int.max)
        var capCalls = 0
        for i in 0..<65 {
            _ = try await cappedEntries.data(for: key("entry-\(i)")) { capCalls += 1; return Data([1]) }
        }
        expect(cappedEntries.statistics.entries == 64 && cappedEntries.statistics.bytes == 64,
               "DI cannot increase the hard 64-entry limit")
        _ = try await cappedEntries.data(for: key("entry-0")) { capCalls += 1; return Data([2]) }
        expect(capCalls == 66 && cappedEntries.statistics.entries == 64, "hard entry limit evicts oldest")
        let disabled = Cache(byteLimit: Int.min, entryLimit: Int.min)
        var disabledCalls = 0
        for _ in 0..<2 { _ = try await disabled.data(for: key("disabled")) { disabledCalls += 1; return Data([1]) } }
        expect(disabledCalls == 2 && disabled.statistics.entries == 0, "negative limits clamp to disabled storage")
    }

    static func singleflight() async throws {
        let cache = Cache()
        let gate = Gate()
        var unexpectedLoads = 0
        let first = Task { @MainActor in
            try await cache.data(for: key("shared", pixels: 1)) { try await gate.read() }
        }
        await until { gate.calls == 1 }
        let second = Task { @MainActor in
            try await cache.data(for: key("shared", pixels: 320)) { unexpectedLoads += 1; return Data([99]) }
        }
        await until { cache.statistics.waiters == 2 }
        expect(cache.statistics.flights == 1 && gate.calls == 1 && unexpectedLoads == 0,
               "identical canonical keys have one shared flight")
        let independentGate = Gate()
        let independent = Task { @MainActor in
            try await cache.data(for: key("shared", scope: "fixture-account-b")) { try await independentGate.read() }
        }
        await until { independentGate.calls == 1 }
        expect(cache.statistics.flights == 2 && cache.statistics.waiters == 3, "different accounts never coalesce")
        gate.succeed(Data([6]))
        let one = try await first.value
        let two = try await second.value
        expect(one == Data([6]) && two == one && !gate.cancelledOnReturn, "all shared waiters receive the same data")
        independentGate.succeed(Data([7]))
        let other = try await independent.value
        expect(other == Data([7]) && cache.statistics.flights == 0, "separate flights finish independently")

        let nilGate = Gate()
        let nilFirst = Task { @MainActor in
            try await cache.data(for: key("nil", pixels: 321)) { try await nilGate.read() }
        }
        await until { nilGate.calls == 1 }
        let nilSecond = Task { @MainActor in
            try await cache.data(for: key("nil", pixels: Int.max)) { unexpectedLoads += 1; return Data([99]) }
        }
        await until { cache.statistics.waiters == 2 }
        nilGate.succeed(nil)
        let nilOne = try await nilFirst.value
        let nilTwo = try await nilSecond.value
        let negativeHit = try await cache.data(for: key("nil", pixels: 700)) { unexpectedLoads += 1; return Data([99]) }
        expect(nilOne == nil && nilTwo == nil && negativeHit == nil && unexpectedLoads == 0,
               "singleflight nil is shared and negatively cached")

        let failedGate = Gate()
        let failedFirst = Task { @MainActor in
            try await cache.data(for: key("failed")) { try await failedGate.read() }
        }
        await until { failedGate.calls == 1 }
        let failedSecond = Task { @MainActor in
            try await cache.data(for: key("failed")) { unexpectedLoads += 1; return Data([99]) }
        }
        await until { cache.statistics.waiters == 2 }
        failedGate.fail()
        await invalid { try await failedFirst.value }
        await invalid { try await failedSecond.value }
        var retries = 0
        let retry = try await cache.data(for: key("failed")) { retries += 1; return Data([8]) }
        expect(retry == Data([8]) && retries == 1 && unexpectedLoads == 0,
               "failed singleflight is removed; next request can retry")
    }

    static func clearAndLateCompletion() async throws {
        let cache = Cache()
        _ = try await cache.data(for: key("warm-positive")) { Data([1]) }
        _ = try await cache.data(for: key("warm-negative")) { nil }
        let oldGate = Gate()
        let otherOldGate = Gate()
        let oldFirst = Task { @MainActor in
            try await cache.data(for: key("same")) { try await oldGate.read() }
        }
        await until { oldGate.calls == 1 }
        let oldSecond = Task { @MainActor in
            try await cache.data(for: key("same")) { preconditionFailure("duplicate old flight") }
        }
        await until { cache.statistics.waiters == 2 }
        let otherOld = Task { @MainActor in
            try await cache.data(for: key("other")) { try await otherOldGate.read() }
        }
        await until { otherOldGate.calls == 1 }
        cache.clear()
        expect(cache.statistics.entries == 0 && cache.statistics.bytes == 0 &&
               cache.statistics.flights == 0 && cache.statistics.waiters == 0,
               "logout clears positives, negatives, order, bytes and all registered flights")
        // These must finish BEFORE either uncooperative callback acknowledges cancel.
        await cancelled(oldFirst)
        await cancelled(oldSecond)
        await cancelled(otherOld)
        expect(oldGate.returned == 0 && otherOldGate.returned == 0, "clear promptly cancels every waiting caller")

        let replacementGate = Gate()
        let replacement = Task { @MainActor in
            try await cache.data(for: key("same")) { try await replacementGate.read() }
        }
        await until { replacementGate.calls == 1 }
        oldGate.succeed(Data([88]))
        otherOldGate.succeed(nil)
        await until { oldGate.returned == 1 && otherOldGate.returned == 1 }
        await settle()
        expect(oldGate.cancelledOnReturn && otherOldGate.cancelledOnReturn,
               "clear cancels workers even when loaders ignore cancellation")
        expect(cache.statistics.flights == 1 && cache.statistics.waiters == 1 && cache.statistics.entries == 0,
               "late old data/nil cannot cache or remove the same-key replacement ticket")
        var unexpectedLoads = 0
        let joinedReplacement = Task { @MainActor in
            try await cache.data(for: key("same")) { unexpectedLoads += 1; return Data([99]) }
        }
        await until { cache.statistics.waiters == 2 }
        replacementGate.succeed(Data([9]))
        let newOne = try await replacement.value
        let newTwo = try await joinedReplacement.value
        let cached = try await cache.data(for: key("same")) { unexpectedLoads += 1; return Data([99]) }
        expect(newOne == Data([9]) && newTwo == newOne && cached == newOne && unexpectedLoads == 0,
               "only the new epoch publishes and caches artwork")
        let reloadedMissing = try await cache.data(for: key("warm-negative")) { Data([2]) }
        expect(reloadedMissing == Data([2]), "clear discarded the old negative cache")

        let clearingInsideLoad = Cache()
        let inside = Task { @MainActor in
            try await clearingInsideLoad.data(for: key("inside")) {
                clearingInsideLoad.clear()
                return Data([3])
            }
        }
        await cancelled(inside)
        expect(clearingInsideLoad.statistics.entries == 0 && clearingInsideLoad.statistics.flights == 0,
               "clear during loader execution also blocks publication")
    }

    static func waiterCancellation() async throws {
        let cache = Cache()
        var unexpectedLoads = 0
        let alreadyCancelled = Task { @MainActor in
            try await cache.data(for: key("pre-cancelled")) { unexpectedLoads += 1; return Data([99]) }
        }
        alreadyCancelled.cancel() // Main actor has not yielded to its body yet.
        await cancelled(alreadyCancelled)
        expect(unexpectedLoads == 0 && cache.statistics.flights == 0, "pre-cancelled caller never loads")

        let gate = Gate()
        let leaving = Task { @MainActor in
            try await cache.data(for: key("shared")) { try await gate.read() }
        }
        await until { gate.calls == 1 }
        let staying = Task { @MainActor in
            try await cache.data(for: key("shared")) { unexpectedLoads += 1; return Data([99]) }
        }
        await until { cache.statistics.waiters == 2 }
        leaving.cancel()
        await cancelled(leaving)
        expect(cache.statistics.flights == 1 && cache.statistics.waiters == 1 && gate.returned == 0,
               "cancelled waiter exits promptly without cancelling the shared worker")
        gate.succeed(Data([4]))
        let survivor = try await staying.value
        let cached = try await cache.data(for: key("shared")) { unexpectedLoads += 1; return Data([99]) }
        expect(survivor == Data([4]) && cached == survivor && !gate.cancelledOnReturn && unexpectedLoads == 0,
               "another waiter still receives and caches uncancelled artwork")
        let cancelledHit = Task { @MainActor in
            try await cache.data(for: key("shared")) { preconditionFailure("cached hit loaded") }
        }
        cancelledHit.cancel()
        await cancelled(cancelledHit)
        expect(cache.statistics.entries == 1, "cancelled cache hit does not erase cached artwork")

        let orphanCache = Cache()
        let orphanGate = Gate()
        let onlyWaiter = Task { @MainActor in
            try await orphanCache.data(for: key("orphan")) { try await orphanGate.read() }
        }
        await until { orphanGate.calls == 1 }
        onlyWaiter.cancel()
        await cancelled(onlyWaiter)
        expect(orphanCache.statistics.flights == 0 && orphanCache.statistics.waiters == 0 &&
               orphanCache.statistics.entries == 0 && orphanGate.returned == 0,
               "last waiter cancellation immediately removes its flight without awaiting the loader")
        let freshGate = Gate()
        let laterWaiter = Task { @MainActor in
            try await orphanCache.data(for: key("orphan")) { try await freshGate.read() }
        }
        await until { freshGate.calls == 1 }
        orphanGate.succeed(Data([77]))
        await until { orphanGate.returned == 1 }
        await settle()
        expect(orphanGate.cancelledOnReturn && orphanCache.statistics.flights == 1 &&
               orphanCache.statistics.waiters == 1 && orphanCache.statistics.entries == 0,
               "last waiter cancels worker; late data cannot cache or remove a same-epoch replacement ticket")
        freshGate.succeed(Data([5]))
        let later = try await laterWaiter.value
        let laterCached = try await orphanCache.data(for: key("orphan")) { preconditionFailure("replacement not cached") }
        expect(later == Data([5]) && laterCached == later && freshGate.calls == 1 && !freshGate.cancelledOnReturn,
               "a new caller starts fresh and only the replacement artwork is published and cached")

        // Schedule an old waiter's cancellation handler, clear synchronously, and
        // start the same key again before releasing the old callback.
        let raced = Cache()
        let oldGate = Gate()
        let old = Task { @MainActor in
            try await raced.data(for: key("race")) { try await oldGate.read() }
        }
        await until { oldGate.calls == 1 }
        old.cancel()
        raced.clear()
        let newGate = Gate()
        let newer = Task { @MainActor in
            try await raced.data(for: key("race")) { try await newGate.read() }
        }
        await until { newGate.calls == 1 }
        await cancelled(old)
        oldGate.succeed(Data([77]))
        await until { oldGate.returned == 1 }
        await settle()
        expect(raced.statistics.flights == 1 && raced.statistics.waiters == 1 && raced.statistics.entries == 0,
               "old cancellation handler and old completion cannot remove a newer flight")
        newGate.succeed(Data([6]))
        let newest = try await newer.value
        let newestCached = try await raced.data(for: key("race")) { preconditionFailure("new data corrupted") }
        expect(newest == Data([6]) && newestCached == newest,
               "cancelled old waiter never publishes over newer artwork")
    }
}
