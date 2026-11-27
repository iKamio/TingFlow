import Foundation

/// Fixed-capacity, allocation-free producer. Caller serializes access; no PCM is retained.
struct PlaybackOnsetEnergy: Equatable {
    var seconds: Double = 0
    var rms: Double = 0
    var high: Double = 0
}

final class PlaybackOnsetEnvelope {
    static let capacity = 1_200
    static let maximumSeconds = 12.0
    private let ring: UnsafeMutablePointer<PlaybackOnsetEnergy>
    private var write = 0
    private(set) var count = 0
    private var frames = 0
    private var sum = 0.0, difference = 0.0, first = 0.0
    private var expected = Double.nan
    private var lower = 0.0, upper = 0.0
    private(set) var armed = false

    init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: PlaybackOnsetEnergy(), count: Self.capacity)
    }
    deinit { ring.deinitialize(count: Self.capacity); ring.deallocate() }

    @discardableResult func arm(start: Double, seconds: Double) -> Bool {
        clear()
        guard start.isFinite, start >= 0, seconds.isFinite, seconds > 0,
              seconds <= Self.maximumSeconds, (start + seconds).isFinite else { return false }
        lower = start; upper = start + seconds; armed = true
        return true
    }
    func clear() { armed = false; resetContinuity() }
    /// Retain the requested window, but never join envelopes across a decoder discontinuity.
    func resetContinuity() {
        write = 0; count = 0; frames = 0; sum = 0; difference = 0; expected = .nan
    }
    /// Returns false for a discontinuity; caller also resets its channel history.
    func begin(start: Double, duration: Double, discontinuity: Bool) -> Bool {
        let continuous = !discontinuity && (!expected.isFinite || abs(start - expected) <= 0.002)
        if !continuous { resetContinuity() }
        expected = start + duration
        return continuous
    }
    func intersects(start: Double, end: Double) -> Bool { armed && end > lower && start < upper }
    func append(power: Double, highPower: Double, seconds: Double, windowFrames: Int) {
        guard armed, seconds >= lower, seconds < upper else { return }
        if frames == 0 { first = seconds }
        sum += power; difference += highPower; frames += 1
        if frames == windowFrames {
            ring[write] = PlaybackOnsetEnergy(seconds: first,
                rms: sqrt(sum / Double(frames)), high: sqrt(difference / Double(frames)))
            write = (write + 1) % Self.capacity
            count = min(count + 1, Self.capacity)
            frames = 0; sum = 0; difference = 0
        }
    }
    /// Destination is allocated by the non-real-time reader, before acquiring its lock.
    func copy(into destination: UnsafeMutablePointer<PlaybackOnsetEnergy>) -> Int {
        let oldest = (write - count + Self.capacity) % Self.capacity
        for index in 0..<count { destination[index] = ring[(oldest + index) % Self.capacity] }
        return count
    }
    /// Run off the render thread. Same attack thresholds as BeatOnsetAnalysis, not BPM/bar inference.
    static func onsets(_ energy: [PlaybackOnsetEnergy]) -> [BeatOnset] {
        guard energy.count >= 8 else { return [] }
        var result: [BeatOnset] = [], last = -100.0
        result.reserveCapacity(64)
        for index in 2..<(energy.count - 1) {
            let current = energy[index]
            guard current.seconds.isFinite, current.rms.isFinite, current.high.isFinite else { continue }
            let first = max(0, index - 20)
            var floor = 0.0
            for prior in first..<index { floor += energy[prior].rms }
            floor /= Double(index - first)
            let rise = max(0, current.rms - energy[index - 1].rms)
                + 0.3 * max(0, current.high - energy[index - 1].high)
            guard current.rms > 0.025, current.rms > max(0.015, floor * 1.7),
                  rise > max(0.018, floor * 0.7), current.rms >= energy[index + 1].rms * 0.65,
                  current.seconds - last >= 0.12 else { continue }
            result.append(BeatOnset(seconds: current.seconds, strength: min(1, rise)))
            last = current.seconds
            if result.count == 64 { break }
        }
        return result
    }
}
