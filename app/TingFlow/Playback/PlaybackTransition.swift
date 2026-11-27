import Foundation

/// App-owned transitions, not Apple's proprietary AutoMix. Pure, offline-testable policy.
enum PlaybackTransitionMode: String, CaseIterable, Identifiable {
    case off, fixed, beat
    var id: String { rawValue }
    var title: String {
        switch self { case .off: return "关闭"; case .fixed: return "固定淡化"; case .beat: return "本机起音对齐" }
    }
}
enum PlaybackTransitionCurve: String, CaseIterable, Identifiable {
    case linear, equalPower
    var id: String { rawValue }
    var title: String { self == .linear ? "线性" : "等功率" }
}
struct PlaybackTransitionSettings: Equatable {
    static let modeKey = "tingflow.playback.transition-mode"
    static let durationKey = "tingflow.playback.transition-duration"
    static let curveKey = "tingflow.playback.transition-curve"
    static let changed = Notification.Name("TingFlow.playbackTransitionSettingsChanged")
    // The caller explicitly chose fixed crossfade and beat-aware transition; keep the
    // conventional three-second fade enabled unless they turn it off.
    var mode: PlaybackTransitionMode = .fixed
    var seconds: Double = 3
    var curve: PlaybackTransitionCurve = .equalPower
    static func boundedSeconds(_ value: Double) -> Double { value.isFinite ? min(8, max(1, value)) : 3 }
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(mode: PlaybackTransitionMode(rawValue: defaults.string(forKey: modeKey) ?? PlaybackTransitionMode.fixed.rawValue) ?? .fixed,
             seconds: boundedSeconds((defaults.object(forKey: durationKey) as? Double) ?? 3),
             curve: PlaybackTransitionCurve(rawValue: defaults.string(forKey: curveKey) ?? "") ?? .equalPower)
    }
}
struct PlaybackTransitionTicket: Equatable {
    // Two attempts for the same song/context must never accept each other's late completion.
    let id = UUID()
    let generation: UUID
    let queueRevision: UUID
    let targetIndex: Int
    let songID: String
}
/// A cancellation/pause/reorder is not permission to retry a refused preload.
struct PlaybackTransitionAttemptGate {
    private(set) var attempted: Set<Int> = []
    mutating func claim(_ index: Int) -> Bool { attempted.insert(index).inserted }
    mutating func reset() { attempted.removeAll() }
}
enum PlaybackTransitionMath {
    static func gains(progress: Double, curve: PlaybackTransitionCurve) -> (outgoing: Float, incoming: Float) {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        // Exact endpoints also avoid leaving the retired deck at a tiny nonzero gain.
        if p == 0 { return (1, 0) }
        if p == 1 { return (0, 1) }
        if curve == .linear { return (Float(1 - p), Float(p)) }
        return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
    }
    /// Unknown/live durations and very short clips never overlap. Use decoded item duration, not catalog hints.
    static func eligible(duration: Double, fade: Double) -> Bool {
        duration.isFinite && duration >= max(12, boundedFade(fade) * 2 + 2)
    }
    static func boundedFade(_ value: Double) -> Double { PlaybackTransitionSettings.boundedSeconds(value) }
    /// A prepared flag is not proof of a playable item. This gate is shared by the
    /// timer and natural-end path; stale tickets are checked separately by the owner.
    static func shouldPromoteAtEnd(wantsPlay: Bool, incomingPrepared: Bool, repeatsOne: Bool,
                                   incomingReady: Bool, incomingEligible: Bool, incomingEnded: Bool) -> Bool {
        wantsPlay && incomingPrepared && !repeatsOne && incomingReady && incomingEligible && !incomingEnded
    }
    static func progress(position: Double, start: Double, duration: Double) -> Double? {
        guard position.isFinite, start.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, (position - start) / duration))
    }
    static func nextIndex(order: [Int], current: Int, wraps: Bool, repeatsOne: Bool) -> Int? {
        guard !repeatsOne, order.count > 1, let position = order.firstIndex(of: current) else { return nil }
        if position + 1 < order.count { return order[position + 1] }
        return wraps ? order.first : nil
    }
}

/// Pure gates shared by the owner tasks and offline regression executable.
/// Deadlines use monotonic uptime, never Date or media progress alone.
enum PlaybackTransitionPreparationPolicy {
    static let restoreBudget = 0.75
    static func isCurrent(_ operation: UUID, _ current: UUID?) -> Bool { operation == current }
    static func probeBudget(position: Double, duration: Double, fade: Double) -> Double {
        guard position.isFinite, duration.isFinite, fade.isFinite else { return 0 }
        // Reserve rewind/startup time before even the earliest allowable onset shift.
        return min(3, max(0, duration - PlaybackTransitionMath.boundedFade(fade)
            - BeatOnsetAnalysis.maximumShift - position - restoreBudget - 0.25))
    }
    static func continueProbe(media: Double, now: Double, started: Double, budget: Double) -> Bool {
        media.isFinite && media >= 0 && media < 3 && now.isFinite && started.isFinite
            && budget.isFinite && budget > 0 && now >= started && now - started < min(3, budget)
    }
    static func acceptsRewind(operation: UUID, current: UUID?, completed: Bool,
                              position: Double, target: Double, now: Double, deadline: Double) -> Bool {
        isCurrent(operation, current) && completed && position.isFinite && target.isFinite
            && target >= 0 && abs(position - target) <= 0.03
            && now.isFinite && deadline.isFinite && now < deadline
    }
    static func acceptsPlan(_ plan: BeatTransitionPlan, position: Double) -> Bool {
        position.isFinite && plan.outgoingStart.isFinite && plan.incomingStart.isFinite
            && plan.fadeSeconds.isFinite && plan.fadeSeconds >= 0.65 && plan.fadeSeconds <= 8.35
            && plan.incomingStart >= 0 && plan.incomingStart <= BeatOnsetAnalysis.maximumShift
            && plan.outgoingStart - position >= restoreBudget + 0.25
    }
    static func canPrepare(current: Bool, restored: Bool, ready: Bool, position: Double,
                           nominalStart: Double, now: Double, deadline: Double) -> Bool {
        current && restored && ready && position.isFinite && nominalStart.isFinite && position < nominalStart
            && now.isFinite && deadline.isFinite && now < deadline
    }
    /// At most two owner-timer ticks of scheduling jitter, not a license to backfill a missed plan.
    static func missedPlan(start: Double, position: Double) -> Bool {
        !start.isFinite || !position.isFinite || position - start > 0.08
    }
}
