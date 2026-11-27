import Foundation

@main struct PublicArtworkCacheChecks {
    enum SyntheticError: Error { case failed }
    actor Gate {
        private var callback: CheckedContinuation<Data, Error>?
        private(set) var calls = 0
        func read() async throws -> Data {
            calls += 1
            return try await withCheckedThrowingContinuation { callback = $0 }
        }
        func succeed(_ data: Data) { let value = callback; callback = nil; value!.resume(returning: data) }
    }
    static func check(_ condition: Bool, _ label: String) { precondition(condition, label) }
    static func key(_ id: String) -> URL { URL(string: "https://p1.music.126.net/\(id).jpg")! }
    static func until(_ ready: () async -> Bool) async {
        for _ in 0..<20_000 {
            if await ready() { return }
            await Task.yield()
        }
        preconditionFailure("fixture checkpoint unavailable")
    }
    static func cancelled(_ task: Task<Data, Error>) async {
        do { _ = try await task.value; preconditionFailure("expected cancellation") }
        catch is CancellationError {}
        catch { preconditionFailure("incorrect cancellation result") }
    }
    static func main() async throws {
        let cache = PublicArtworkCache(byteLimit: 3, entryLimit: 2)
        _ = try await cache.data(for: key("a")) { Data([1]) }
        _ = try await cache.data(for: key("b")) { Data([2]) }
        _ = try await cache.data(for: key("a")) { preconditionFailure("cache hit reloaded") }
        _ = try await cache.data(for: key("c")) { Data([3]) }
        _ = try await cache.data(for: key("a")) { preconditionFailure("hot LRU entry evicted") }
        let b = try await cache.data(for: key("b")) { Data([9]) }
        check(b == Data([9]), "least recently used entry reloads")
        _ = try await cache.data(for: key("large")) { Data([1, 2, 3, 4]) }
        check(await cache.statistics.bytes <= 3, "memory byte bound excludes oversized entries")
        do { _ = try await cache.data(for: key("failure")) { throw SyntheticError.failed } }
        catch is SyntheticError {}
        let retry = try await cache.data(for: key("failure")) { Data([7]) }
        check(retry == Data([7]), "transient error is never cached")

        let shared = PublicArtworkCache()
        let gate = Gate()
        let first = Task { try await shared.data(for: key("shared")) { try await gate.read() } }
        await until { await gate.calls == 1 }
        let second = Task { try await shared.data(for: key("shared")) { preconditionFailure("same-key download duplicated") } }
        await until { await shared.statistics.waiters == 2 }
        first.cancel()
        await cancelled(first)
        check(await shared.statistics.waiters == 1, "one leaving row does not cancel the remaining row")
        await gate.succeed(Data([4]))
        check(try await second.value == Data([4]), "surviving consumer receives shared result")
        _ = try await shared.data(for: key("shared")) { preconditionFailure("shared result not cached") }

        let oldGate = Gate()
        let old = Task { try await shared.data(for: key("replace")) { try await oldGate.read() } }
        await until { await oldGate.calls == 1 }
        old.cancel(); await cancelled(old)
        check(await shared.statistics.flights == 0, "last cancellation removes flight promptly")
        let newGate = Gate()
        let replacement = Task { try await shared.data(for: key("replace")) { try await newGate.read() } }
        await until { await newGate.calls == 1 }
        await oldGate.succeed(Data([99]))
        for _ in 0..<64 { await Task.yield() }
        check(await shared.statistics.flights == 1, "late cancelled worker cannot remove replacement flight")
        await newGate.succeed(Data([8]))
        check(try await replacement.value == Data([8]), "replacement result is current")
        let current = try await shared.data(for: key("replace")) { preconditionFailure("replacement not cached") }
        check(current == Data([8]), "late cancelled bytes never enter cache")
        print("PASS: public artwork LRU, byte bounds, retry, coalescing and cancellation checks (synthetic offline)")
    }
}
