import Foundation

/// Account-scoped raw artwork, in memory only. The loader must return nil only
/// for a genuine missing artwork (for example, an authenticated 404).
@MainActor public final class ServerArtworkCache {
    public struct Key: Hashable, Sendable {
        public let scope: String
        public let id: String
        public let revision: String?
        public let bucketPixels: Int
        public var pixels: Int { bucketPixels }

        public init(scope: String, id: String, revision: String? = nil, pixels: Int) {
            self.scope = scope
            self.id = id
            self.revision = revision
            self.bucketPixels = ServerArtworkCache.pixels(pixels)
        }

        fileprivate var isValid: Bool {
            func valid(_ text: String, limit: Int, allowEmpty: Bool = false) -> Bool {
                (allowEmpty || !text.isEmpty) && text.utf8.count <= limit &&
                    text.rangeOfCharacter(from: .controlCharacters) == nil
            }
            return valid(scope, limit: 4_096) && valid(id, limit: 2_048) &&
                (revision.map { valid($0, limit: 512, allowEmpty: true) } ?? true)
        }
    }

    /// Fixed, content-free failures; never retain or expose a loader's error body.
    public enum Failure: Error, Equatable, Sendable { case invalidData }

    public nonisolated static func pixels(_ requested: Int) -> Int {
        requested <= 320 ? 320 : 700
    }

    private struct Entry {
        let data: Data?
        let expiresAt: Date?
        var cost: Int { data?.count ?? 0 }
    }

    @MainActor private final class Flight {
        let epoch: UInt64
        let ticket = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data?, Error>] = [:]
        init(epoch: UInt64) { self.epoch = epoch }
    }

    // Counts only: the standalone checks cannot inspect keys or raw artwork.
    struct Statistics {
        let entries: Int
        let bytes: Int
        let flights: Int
        let waiters: Int
    }
    var statistics: Statistics {
        Statistics(entries: entries.count, bytes: storedBytes, flights: flights.count,
                   waiters: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    private let byteLimit: Int
    private let entryLimit: Int
    private let missingTTL: TimeInterval
    private let now: () -> Date
    private var epoch: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = [] // Oldest first; bounded to 64.
    private var storedBytes = 0
    private var flights: [Key: Flight] = [:]

    public init(byteLimit: Int = 12_000_000, entryLimit: Int = 64,
                missingTTL: TimeInterval = 60, now: @escaping () -> Date = { Date() }) {
        self.byteLimit = min(12_000_000, max(0, byteLimit))
        self.entryLimit = min(64, max(0, entryLimit))
        self.missingTTL = missingTTL.isFinite ? max(0, missingTTL) : 60
        self.now = now
    }

    public func data(for key: Key,
                     load: @escaping @MainActor () async throws -> Data?) async throws -> Data? {
        try Task.checkCancellation()
        guard key.isValid else { throw Failure.invalidData }
        if let entry = entries[key] {
            if let expiry = entry.expiresAt, now() >= expiry {
                removeEntry(key)
            } else {
                touch(key)
                return entry.data
            }
        }

        let requestEpoch = epoch
        let waiterID = UUID()
        let value: Data?
        do {
            value = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data?, Error>) in
                    guard !Task.isCancelled, self.epoch == requestEpoch else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let flight = self.flights[key] {
                        flight.waiters[waiterID] = continuation
                    } else {
                        self.start(key, epoch: requestEpoch, waiterID: waiterID,
                                   continuation: continuation, load: load)
                    }
                }
            }, onCancel: {
                // Cancel this waiter, never the shared worker. An uncooperative
                // loader cannot hold a cancelled caller (or logout) hostage.
                Task { @MainActor [weak self] in
                    self?.cancelWaiter(key, epoch: requestEpoch, waiterID: waiterID)
                }
            })
        } catch {
            if Task.isCancelled || epoch != requestEpoch { throw CancellationError() }
            throw error
        }
        // clear() may run after resume but before this caller gets its executor.
        try Task.checkCancellation()
        guard epoch == requestEpoch else { throw CancellationError() }
        return value
    }

    public func clear() {
        epoch &+= 1
        let previous = Array(flights.values)
        flights.removeAll()
        entries.removeAll()
        order.removeAll()
        storedBytes = 0
        for flight in previous {
            flight.task?.cancel()
            let waiters = Array(flight.waiters.values)
            flight.waiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }
    }

    private func start(_ key: Key, epoch: UInt64, waiterID: UUID,
                       continuation: CheckedContinuation<Data?, Error>,
                       load: @escaping @MainActor () async throws -> Data?) {
        let flight = Flight(epoch: epoch)
        let ticket = flight.ticket
        flight.waiters[waiterID] = continuation
        flights[key] = flight
        flight.task = Task { @MainActor [weak self] in
            let result: Result<Data?, Error>
            do {
                try Task.checkCancellation()
                let data = try await load()
                try Task.checkCancellation()
                if let data = data, data.isEmpty || data.count > 4_000_000 {
                    throw Failure.invalidData
                }
                result = .success(data)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    result = .failure(CancellationError())
                } else {
                    result = .failure(Failure.invalidData)
                }
            }
            self?.finish(key, epoch: epoch, ticket: ticket, result: result)
        }
    }

    private func cancelWaiter(_ key: Key, epoch: UInt64, waiterID: UUID) {
        guard self.epoch == epoch, let flight = flights[key], flight.epoch == epoch,
              let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        if flight.waiters.isEmpty {
            // Offscreen artwork has no remaining consumer. Remove the ticket
            // before cancellation so a same-key caller can start a fresh flight.
            flights.removeValue(forKey: key)
            flight.task?.cancel()
            flight.task = nil
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(_ key: Key, epoch: UInt64, ticket: UUID,
                        result: Result<Data?, Error>) {
        // Both checks are essential: an old worker must not remove a replacement.
        guard self.epoch == epoch, let flight = flights[key],
              flight.epoch == epoch, flight.ticket == ticket else { return }
        flights.removeValue(forKey: key)
        if case .success(let data) = result { insert(data, for: key) }
        let waiters = Array(flight.waiters.values)
        flight.waiters.removeAll()
        flight.task = nil
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func removeEntry(_ key: Key) {
        if let removed = entries.removeValue(forKey: key) { storedBytes -= removed.cost }
        order.removeAll { $0 == key }
    }

    private func insert(_ data: Data?, for key: Key) {
        let cost = data?.count ?? 0
        guard entryLimit > 0, cost <= byteLimit, data != nil || missingTTL > 0 else { return }
        removeEntry(key)
        while entries.count >= entryLimit || storedBytes + cost > byteLimit {
            guard let oldest = order.first else { return }
            removeEntry(oldest)
        }
        entries[key] = Entry(data: data, expiresAt: data == nil ? now().addingTimeInterval(missingTTL) : nil)
        storedBytes += cost
        touch(key)
    }
}
