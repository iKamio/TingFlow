import Foundation

/// Value-type accounting only. Its owner must serialize access (e.g. MainActor),
/// supply monotonic uptime and call seek() before every discontinuous seek.
/// Neither attachment/readiness nor a playing flag alone proves listening.
struct ListeningSession {
    struct Snapshot {
        let id: UUID
        let song: Song
        let scope: String
        let listenedSeconds: Double
        var seconds: Int { Int(listenedSeconds.rounded(.down)) }
    }

    let id: UUID
    let song: Song
    let scope: String
    func belongs(to currentScope: String?) -> Bool { scope == currentScope && song.platform == .netease }
    private(set) var listenedSeconds: Double = 0
    private(set) var didStart = false
    private(set) var isFinished = false
    private let durationCap: Double
    private var anchor: (position: Double, monotonic: Double)?

    /// nil uses a positive known song duration, otherwise a 24h safety cap.
    /// An explicitly supplied invalid/negative/zero duration fails closed to 0.
    init(song: Song, scope: String, duration: Double? = nil, id: UUID = UUID()) {
        self.id = id
        self.song = song
        self.scope = scope
        let known = duration ?? (song.duration > 0 && song.duration.isFinite ? song.duration : nil)
        durationCap = known.map { $0.isFinite ? min(86_400, max(0, $0)) : 0 } ?? 86_400
    }

    /// Returns true ONCE, at the first positively credited progress interval.
    /// Sample actual playing/rate state, not requested play or item-ready state.
    /// Pausing discards the tail interval; resuming requires a fresh baseline.
    @discardableResult
    mutating func sample(position: Double, monotonic: Double, isPlaying: Bool) -> Bool {
        guard !isFinished else { return false }
        guard isPlaying, position.isFinite, monotonic.isFinite,
              position >= 0, monotonic >= 0 else {
            anchor = nil
            return false
        }
        let previous = anchor
        anchor = (position, monotonic)
        guard let previous else { return false }
        let wall = monotonic - previous.monotonic
        let progress = position - previous.position
        // Stale clocks cannot become a reusable earlier baseline.
        guard wall > 0 else { anchor = nil; return false }
        // Suspended callbacks, seeks, stalls and reversals are not listening.
        guard wall <= 10, progress > 0, progress <= wall + 1 else { return false }
        let credited = min(min(progress, wall), min(5, durationCap - listenedSeconds))
        guard credited > 0 else { return false }
        listenedSeconds += credited
        guard !didStart else { return false }
        didStart = true
        return true
    }

    mutating func seek() { anchor = nil }

    /// No synthetic minimum time. A sub-second/unobserved session has no finish
    /// report. All finishes, including nil, permanently close this value.
    /// Keep this value in one owner; copying it is not a cross-copy dedupe ledger.
    mutating func finish() -> Snapshot? {
        guard !isFinished else { return nil }
        isFinished = true
        anchor = nil
        guard listenedSeconds >= 1 else { return nil }
        return Snapshot(id: id, song: song, scope: scope, listenedSeconds: listenedSeconds)
    }
}
