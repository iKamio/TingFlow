import Foundation

/// Bounded public-image memory cache. Each visible consumer owns a waiter, not
/// the shared download; scrolling one row offscreen cannot cancel another row.
actor PublicArtworkCache {
    private final class Flight {
        let ticket = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    }
    private let byteLimit: Int
    private let entryLimit: Int
    private var entries: [URL: Data] = [:]
    private var order: [URL] = []
    private var bytes = 0
    private var flights: [URL: Flight] = [:]

    struct Statistics { let entries: Int; let bytes: Int; let flights: Int; let waiters: Int }
    var statistics: Statistics {
        Statistics(entries: entries.count, bytes: bytes, flights: flights.count,
                   waiters: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    init(byteLimit: Int = 16_000_000, entryLimit: Int = 80) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }

    func data(for key: URL, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        if let value = entries[key] {
            touch(key)
            return value
        }
        let waiter = UUID()
        let value = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let flight = flights[key] {
                    flight.waiters[waiter] = continuation
                } else {
                    let flight = Flight()
                    flight.waiters[waiter] = continuation
                    flights[key] = flight
                    let ticket = flight.ticket
                    flight.task = Task { [weak self] in
                        let result: Result<Data, Error>
                        do {
                            let data = try await load()
                            try Task.checkCancellation()
                            result = .success(data)
                        } catch { result = .failure(error) }
                        await self?.finish(key, ticket: ticket, result: result)
                    }
                }
            }
        }, onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        })
        try Task.checkCancellation()
        return value
    }

    private func cancel(_ key: URL, waiter: UUID) {
        guard let flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task?.cancel()
            flight.task = nil
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: URL, ticket: UUID, result: Result<Data, Error>) {
        guard let flight = flights[key], flight.ticket == ticket else { return }
        flights.removeValue(forKey: key)
        if case .success(let data) = result, !data.isEmpty, data.count <= byteLimit, entryLimit > 0 {
            while entries.count >= entryLimit || bytes + data.count > byteLimit {
                guard let oldest = order.first else { break }
                if let removed = entries.removeValue(forKey: oldest) { bytes -= removed.count }
                order.removeFirst()
            }
            entries[key] = data
            bytes += data.count
            touch(key)
        }
        let waiters = Array(flight.waiters.values)
        flight.waiters.removeAll()
        flight.task = nil
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func touch(_ key: URL) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
