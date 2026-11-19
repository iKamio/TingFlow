import Foundation
import Combine

/// A UI deadline must not await a cancelled/uncooperative network child task.
/// These unstructured workers are deliberately independent of SwiftUI's .task lifetime.
@MainActor final class NeteasePlaylistLoadController<Item>: ObservableObject {
    struct Identity: Equatable {
        let playlistID: String
        let accountScope: String
        let sessionScope: String?
        let signedIn: Bool
        var isCurrent: Bool { signedIn && sessionScope == accountScope }
    }
    enum Failure: Equatable {
        case deadline, network, verification, rateLimited, signedOut, invalidData, rejected, other
        var message: String {
            switch self {
            case .deadline: return "读取已超时，已停止等待。请检查网络后手动重试。"
            case .network: return "无法连接网易云，请检查网络后手动重试。"
            case .verification: return "网易云要求安全验证；请在官方 App 检查账号后手动重试。"
            case .rateLimited: return "网易云请求过于频繁，已停止尝试；请稍后手动重试。"
            case .signedOut: return "网易云会话已失效，请返回账号页重新登录。"
            case .invalidData: return "歌单数据不完整或接口格式已变化，请稍后手动重试。"
            case .rejected: return "网易云未接受此请求；请在官方 App 检查账号后手动重试。"
            case .other: return "歌单读取未完成，请稍后手动重试。"
            }
        }
    }
    enum Phase: Equatable { case idle, loading, loaded, cancelled, failed(Failure) }
    typealias Operation = @MainActor () async throws -> [Item]
    typealias Validator = @MainActor () -> Bool
    typealias FailureMapper = @MainActor (Error) -> Failure

    @Published private(set) var items: [Item] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var expectedCount = 0
    let deadlineSeconds: TimeInterval
    private(set) var identity: Identity?
    private var epoch = UUID()
    private var worker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var startedAt: TimeInterval = 0
    private var validate: Validator?
    private let now: () -> TimeInterval
    var isLoading: Bool { phase == .loading }

    init(deadlineSeconds: TimeInterval = 45,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.deadlineSeconds = deadlineSeconds.isFinite ? max(0.01, deadlineSeconds) : 45
        self.now = now
    }
    deinit { worker?.cancel(); watchdog?.cancel() }

    /// Identity changes clear private content; ordinary refresh/cancel never discards good songs.
    func setIdentity(_ newIdentity: Identity) {
        guard identity != newIdentity else { return }
        invalidateWorkers()
        identity = newIdentity
        items = []
        expectedCount = 0
        elapsedSeconds = 0
        phase = .idle
    }

    /// Only the first appearance of an identity loads automatically. Errors/risk/cancellation
    /// survive view reappearance and require an explicit retry instead of a request loop.
    func appear(identity: Identity, expectedCount: Int, operation: @escaping Operation,
                isCurrent: @escaping Validator, failure: @escaping FailureMapper) {
        setIdentity(identity)
        guard phase == .idle else { return }
        load(identity: identity, expectedCount: expectedCount, operation: operation,
             isCurrent: isCurrent, failure: failure)
    }

    func load(identity: Identity, expectedCount: Int, operation: @escaping Operation,
              isCurrent: @escaping Validator, failure: @escaping FailureMapper) {
        setIdentity(identity)
        guard identity.isCurrent, isCurrent() else { return }
        invalidateWorkers()
        let ticket = epoch
        self.expectedCount = max(0, expectedCount)
        elapsedSeconds = 0
        startedAt = now()
        validate = isCurrent
        phase = .loading
        worker = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let items = try await operation()
                self?.complete(ticket: ticket, result: .success(items))
            } catch is CancellationError {
                self?.completeCancellation(ticket: ticket)
            } catch {
                self?.complete(ticket: ticket, result: .failure(failure(error)))
            }
        }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Do not retain the controller across this suspension.
                let delay = self?.remainingDelay(ticket: ticket) ?? 0
                guard delay > 0 else { return }
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard self?.tick(ticket: ticket) == true else { return }
            }
        }
    }

    /// Synchronous logical cancellation: never wait for transport acknowledgment.
    func cancel() {
        let wasLoading = isLoading
        invalidateWorkers()
        if wasLoading { phase = .cancelled }
    }

    private enum Outcome { case success([Item]), failure(Failure) }
    private func accepts(_ ticket: UUID) -> Bool {
        guard epoch == ticket, isLoading else { return false }
        guard identity?.isCurrent == true, validate?() == true else {
            invalidateWorkers()
            items = []
            phase = .idle
            return false
        }
        return true
    }
    private func complete(ticket: UUID, result: Outcome) {
        guard accepts(ticket) else { return }
        // A completion queued ahead of the watchdog must still obey the absolute deadline.
        guard now() - startedAt < deadlineSeconds else { expire(); return }
        invalidateWorkers()
        switch result {
        case .success(let songs): items = songs; phase = .loaded
        case .failure(let reason): phase = .failed(reason)
        }
    }
    private func completeCancellation(ticket: UUID) {
        guard accepts(ticket) else { return }
        invalidateWorkers()
        phase = .cancelled
    }
    private func remainingDelay(ticket: UUID) -> TimeInterval {
        guard epoch == ticket, isLoading else { return 0 }
        return max(0.001, min(0.25, deadlineSeconds - (now() - startedAt)))
    }
    private func tick(ticket: UUID) -> Bool {
        guard accepts(ticket) else { return false }
        let elapsed = max(0, now() - startedAt)
        elapsedSeconds = Int(min(elapsed, deadlineSeconds))
        if elapsed >= deadlineSeconds { expire(); return false }
        return true
    }
    private func expire() {
        invalidateWorkers()
        phase = .failed(.deadline)
    }
    private func invalidateWorkers() {
        // Invalidate FIRST: both cancellation handlers and late successes become harmless.
        epoch = UUID()
        let oldWorker = worker, oldWatchdog = watchdog
        worker = nil; watchdog = nil; validate = nil
        oldWorker?.cancel(); oldWatchdog?.cancel()
    }
}
