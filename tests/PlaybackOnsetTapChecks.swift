import Foundation

/// Standalone offline executable; include PlaybackTransition.swift, BeatTransitionAnalysis.swift,
/// and PlaybackOnsetEnvelope.swift. This tests the envelope/policy, NOT native tap callbacks.
/// Actual tap SDK typechecking is a separate required check_native.sh gate.
@main struct PlaybackOnsetTapChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func energies(_ envelope: PlaybackOnsetEnvelope) -> [PlaybackOnsetEnergy] {
        let copy = UnsafeMutablePointer<PlaybackOnsetEnergy>.allocate(capacity: PlaybackOnsetEnvelope.capacity)
        copy.initialize(repeating: PlaybackOnsetEnergy(), count: PlaybackOnsetEnvelope.capacity)
        defer { copy.deinitialize(count: PlaybackOnsetEnvelope.capacity); copy.deallocate() }
        return Array(UnsafeBufferPointer(start: copy, count: envelope.copy(into: copy)))
    }
    static func feed(_ envelope: PlaybackOnsetEnvelope, start: Double, count: Int, amplitude: Double,
                     window: Int = 80, rate: Double = 8_000) {
        for index in 0..<count {
            let value = index % 2 == 0 ? amplitude : -amplitude
            envelope.append(power: value * value, highPower: 4 * value * value,
                seconds: start + Double(index) / rate, windowFrames: window)
        }
    }
    static func main() {
        let envelope = PlaybackOnsetEnvelope()
        expect(envelope.count == 0 && !envelope.armed, "default is not collecting")
        for pair in [(Double.nan, 1.0), (-1.0, 1.0), (0.0, 0.0), (0.0, 12.01), (0.0, Double.infinity)] {
            expect(!envelope.arm(start: pair.0, seconds: pair.1), "invalid bounded window rejected")
        }
        expect(envelope.arm(start: 100, seconds: 0.1), "finite short window")
        feed(envelope, start: 99.99, count: 960, amplitude: 0.5)
        let clipped = energies(envelope)
        expect(clipped.count == 10, "no samples retained outside absolute asset window")
        expect(abs(clipped[0].seconds - 100) < 0.00001, "window timestamps preserve asset offset")
        expect(abs(clipped[0].rms - 0.5) < 0.00001, "RMS from decoded energy")
        envelope.clear()
        expect(!envelope.armed && energies(envelope).isEmpty, "pause/seek clear disarms and erases logical data")
        feed(envelope, start: 0, count: 800, amplitude: 1)
        expect(envelope.count == 0, "disabled callback retains nothing")

        envelope.arm(start: 0, seconds: 12)
        feed(envelope, start: 0, count: 96_000, amplitude: 0.2)
        expect(envelope.count == 1_200, "twelve seconds is capacity bounded")
        // Adversarial producer: even excess energies within the window wrap, never resize.
        envelope.append(power: 1, highPower: 1, seconds: 11.999, windowFrames: 1)
        let wrapped = energies(envelope)
        expect(wrapped.count == 1_200, "ring overwrite stays bounded")
        expect(abs(wrapped[0].seconds - 0.01) < 0.00001 && wrapped.last!.seconds == 11.999,
            "copy retains chronological ring order")
        envelope.arm(start: 50, seconds: 1)
        expect(envelope.count == 0, "rearm clears previous item evidence")
        expect(envelope.begin(start: 50, duration: 0.01, discontinuity: false), "first block anchors time")
        feed(envelope, start: 50, count: 80, amplitude: 1)
        expect(!envelope.begin(start: 50.5, duration: 0.01, discontinuity: false), "gap invalidates prior envelope")
        expect(envelope.count == 0 && envelope.armed, "gap retains request, not evidence")
        feed(envelope, start: 50.5, count: 80, amplitude: 1)
        expect(!envelope.begin(start: 50.51, duration: 0.01, discontinuity: true), "start-of-stream is a reset")
        expect(envelope.count == 0, "seek cannot join old partial windows")

        var attacks = [PlaybackOnsetEnergy]()
        for index in 0..<300 {
            let amplitude = index == 10 || index == 60 || index == 110 || index == 160 ? 0.8 : 0.0
            attacks.append(PlaybackOnsetEnergy(seconds: 100 + Double(index) * 0.01,
                rms: amplitude, high: amplitude))
        }
        let onsets = PlaybackOnsetEnvelope.onsets(attacks)
        expect(onsets.count == 4 && abs(onsets[0].seconds - 100.1) < 0.00001,
            "real attack energy produces absolute time-tagged BeatOnset")
        expect(PlaybackOnsetEnvelope.onsets([PlaybackOnsetEnergy](repeating: .init(), count: 300)).isEmpty,
            "silence does not invent beats")
        expect(PlaybackOnsetEnvelope.onsets([PlaybackOnsetEnergy](repeating:
            .init(seconds: 0, rms: .nan, high: .infinity), count: 300)).isEmpty, "nonfinite evidence rejected")
        let incoming = onsets.map { BeatOnset(seconds: $0.seconds - 100, strength: $0.strength) }
        let plan = BeatOnsetAnalysis.plan(outgoing: onsets, incoming: incoming, duration: 103.1, requestedFade: 3)
        expect(plan != nil && abs(plan!.outgoingStart - 100.1) < 0.00001,
            "snapshot compatible with existing beat alignment planner")
        expect(BeatOnsetAnalysis.plan(outgoing: [], incoming: incoming, duration: 103.1, requestedFade: 3) == nil,
            "missing decoded tail means fixed-fade fallback")
        // Snapshot-before-cleanup preserves the immutable candidate, never joins the next item.
        let frozen = onsets
        envelope.clear()
        expect(energies(envelope).isEmpty && frozen.count == 4, "snapshot survives cleanup without old ring evidence")
        expect(envelope.arm(start: 200, seconds: 1), "promoted item can arm its own outgoing tail")
        expect(energies(envelope).isEmpty, "promotion rearms an empty window")
        let cancelled = UUID()
        expect(!PlaybackTransitionPreparationPolicy.isCurrent(cancelled, nil), "late installation after disposal rejected")
        expect(!PlaybackTransitionPreparationPolicy.continueProbe(media: 0, now: 103, started: 100, budget: 3),
            "missing native callbacks still has independent wall-clock termination")
        print("PASS: bounded onset envelope, policy deadlines, lifecycle resets and planner compatibility; native tap NOT executed")
    }
}
