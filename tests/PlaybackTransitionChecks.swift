import Foundation

@main struct PlaybackTransitionChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        let suiteName = "TingFlow.PlaybackTransitionChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultsValue = PlaybackTransitionSettings.load(defaults)
        check(defaultsValue.mode == .fixed && defaultsValue.seconds == 3, "chosen 3-second fixed default")
        check(defaultsValue.curve == .equalPower, "equal-power default")
        defaults.set(PlaybackTransitionMode.off.rawValue, forKey: PlaybackTransitionSettings.modeKey)
        defaults.set(99.0, forKey: PlaybackTransitionSettings.durationKey)
        defaults.set(PlaybackTransitionCurve.linear.rawValue, forKey: PlaybackTransitionSettings.curveKey)
        let bounded = PlaybackTransitionSettings.load(defaults)
        check(bounded.mode == .off && bounded.seconds == 8 && bounded.curve == .linear, "persist and bound settings")
        check(PlaybackTransitionSettings.boundedSeconds(.nan) == 3, "nonfinite duration uses safe default")

        let start = PlaybackTransitionMath.gains(progress: 0, curve: .equalPower)
        let end = PlaybackTransitionMath.gains(progress: 1, curve: .equalPower)
        let middle = PlaybackTransitionMath.gains(progress: 0.5, curve: .equalPower)
        check(start.outgoing == 1 && start.incoming == 0, "equal-power start")
        check(end.outgoing == 0 && end.incoming == 1, "equal-power finish")
        check(abs(Double(middle.outgoing * middle.outgoing + middle.incoming * middle.incoming) - 1) < 0.0001, "equal-power constant power")
        let linear = PlaybackTransitionMath.gains(progress: 0.25, curve: .linear)
        check(abs(linear.outgoing - 0.75) < 0.0001 && abs(linear.incoming - 0.25) < 0.0001, "linear envelope")
        let clamped = PlaybackTransitionMath.gains(progress: .infinity, curve: .linear)
        check(clamped.outgoing == 1 && clamped.incoming == 0, "nonfinite envelope fails closed")
        // Exhaust all independent natural-end gate inputs; a prepared flag alone is insufficient.
        for mask in 0..<64 {
            let playing = mask & 1 != 0, prepared = mask & 2 != 0, repeatOne = mask & 4 != 0
            let ready = mask & 8 != 0, eligible = mask & 16 != 0, incomingEnded = mask & 32 != 0
            let result = PlaybackTransitionMath.shouldPromoteAtEnd(
                wantsPlay: playing, incomingPrepared: prepared, repeatsOne: repeatOne,
                incomingReady: ready, incomingEligible: eligible, incomingEnded: incomingEnded
            )
            check(result == (playing && prepared && !repeatOne && ready && eligible && !incomingEnded),
                  "natural-end gate combination \(mask)")
        }
        let generation = UUID(), revision = UUID()
        let firstTicket = PlaybackTransitionTicket(generation: generation, queueRevision: revision, targetIndex: 1, songID: "same")
        let retryTicket = PlaybackTransitionTicket(generation: generation, queueRevision: revision, targetIndex: 1, songID: "same")
        check(firstTicket == firstTicket && firstTicket != retryTicket, "late task cannot match same-target replacement")
        check(PlaybackTransitionMath.progress(position: 119, start: 117, duration: 3) == 2.0 / 3, "media-time fade progress")
        check(PlaybackTransitionMath.progress(position: 120, start: 117, duration: 3) == 1, "final timer tick reaches endpoint")
        check(PlaybackTransitionMath.progress(position: 116, start: 117, duration: 3) == 0, "early progress clamped")
        check(PlaybackTransitionMath.progress(position: .nan, start: 117, duration: 3) == nil, "invalid clock refused")
        check(PlaybackTransitionMath.progress(position: 119, start: 117, duration: 0) == nil, "zero fade refused")
        check(PlaybackTransitionMath.eligible(duration: 120, fade: 3), "long finite track eligible")
        check(!PlaybackTransitionMath.eligible(duration: .infinity, fade: 3), "live duration refused")
        check(!PlaybackTransitionMath.eligible(duration: 8, fade: 3), "short track refused")
        check(PlaybackTransitionMath.nextIndex(order: [0, 2, 1], current: 2, wraps: false, repeatsOne: false) == 1, "respects queue order")
        check(PlaybackTransitionMath.nextIndex(order: [0, 1], current: 1, wraps: true, repeatsOne: false) == 0, "repeat-all wrap")
        check(PlaybackTransitionMath.nextIndex(order: [0, 1], current: 0, wraps: true, repeatsOne: true) == nil, "repeat-one refused")
        check(PlaybackTransitionMath.nextIndex(order: [0], current: 0, wraps: true, repeatsOne: false) == nil, "single-item queue refused")
        var attempts = PlaybackTransitionAttemptGate()
        check(attempts.claim(2) && !attempts.claim(2), "one preload attempt per target")
        attempts.reset()
        check(attempts.claim(2), "explicit context reset permits a new ticket")

        // The following gates are used by actual install/probe/seek/preparation owners.
        let operation = UUID(), replacement = UUID()
        check(PlaybackTransitionPreparationPolicy.isCurrent(operation, operation), "current install token")
        check(!PlaybackTransitionPreparationPolicy.isCurrent(operation, replacement), "stale install rejected")
        check(!PlaybackTransitionPreparationPolicy.isCurrent(operation, nil), "cancelled install rejected")
        check(PlaybackTransitionPreparationPolicy.probeBudget(position: 110, duration: 120, fade: 3) == 3, "probe max three seconds")
        check(PlaybackTransitionPreparationPolicy.probeBudget(position: 117, duration: 120, fade: 3) == 0, "no probe after fade budget")
        check(PlaybackTransitionPreparationPolicy.probeBudget(position: .nan, duration: 120, fade: 3) == 0, "invalid probe budget")
        check(PlaybackTransitionPreparationPolicy.continueProbe(media: 2.9, now: 12.9, started: 10, budget: 3), "probe inside both bounds")
        check(!PlaybackTransitionPreparationPolicy.continueProbe(media: 3, now: 11, started: 10, budget: 3), "media boundary stops fast probe")
        check(!PlaybackTransitionPreparationPolicy.continueProbe(media: 0, now: 13, started: 10, budget: 3), "wall boundary stops stalled probe")
        check(!PlaybackTransitionPreparationPolicy.continueProbe(media: 0, now: 11, started: 10, budget: 1), "shortened transition budget")
        check(!PlaybackTransitionPreparationPolicy.continueProbe(media: .nan, now: 10, started: 10, budget: 3), "invalid media clock")
        for completed in [false, true] {
            for stale in [false, true] {
                for late in [false, true] {
                    for exact in [false, true] {
                        let accepted = PlaybackTransitionPreparationPolicy.acceptsRewind(
                            operation: operation, current: stale ? replacement : operation,
                            completed: completed, position: exact ? 0 : 0.2, target: 0,
                            now: late ? 12 : 10, deadline: 11)
                        check(accepted == (completed && !stale && !late && exact), "rewind completion/stale/timeout/position matrix")
                    }
                }
            }
        }
        for mask in 0..<32 {
            let current = mask & 1 != 0, restored = mask & 2 != 0, ready = mask & 4 != 0
            let mediaInTime = mask & 8 != 0, wallInTime = mask & 16 != 0
            let accepted = PlaybackTransitionPreparationPolicy.canPrepare(current: current, restored: restored,
                ready: ready, position: mediaInTime ? 115 : 118, nominalStart: 117,
                now: wallInTime ? 10 : 12, deadline: 11)
            check(accepted == (current && restored && ready && mediaInTime && wallInTime),
                "only current ready precisely-restored in-budget deck may prepare")
        }
        let futurePlan = BeatTransitionPlan(outgoingStart: 117.1, incomingStart: 0.2, fadeSeconds: 2.9)
        check(PlaybackTransitionPreparationPolicy.acceptsPlan(futurePlan, position: 115), "future plan has rewind reserve")
        check(!PlaybackTransitionPreparationPolicy.acceptsPlan(futurePlan, position: 117.2), "past plan never backfilled")
        check(!PlaybackTransitionPreparationPolicy.acceptsPlan(futurePlan, position: 116.5), "insufficient seek reserve")
        check(PlaybackTransitionPreparationPolicy.missedPlan(start: 117, position: 117.2), "late runtime plan refused")
        check(!PlaybackTransitionPreparationPolicy.missedPlan(start: 117, position: 117.03), "bounded timer jitter only")
        check(!PlaybackTransitionMath.shouldPromoteAtEnd(wantsPlay: true, incomingPrepared: false, repeatsOne: false,
            incomingReady: true, incomingEligible: true, incomingEnded: false), "natural end during probe never promotes")

        let sampleRate = 11_025.0
        var pcm = [Float](repeating: 0, count: Int(sampleRate * 10))
        func pulse(at seconds: Double) {
            let begin = Int(seconds * sampleRate)
            for sample in begin..<min(begin + 1_100, pcm.count) {
                pcm[sample] = Float(0.55 * sin(Double(sample - begin) * 0.18))
            }
        }
        pulse(at: 0.20); pulse(at: 8.10)
        let onsets = BeatOnsetAnalysis.onsets(samples: pcm, sampleRate: sampleRate)
        check(!onsets.isEmpty && onsets.count <= 64, "bounded synthetic onset extraction")
        let plan = BeatOnsetAnalysis.plan(
            outgoing: [BeatOnset(seconds: 8.10, strength: 0.5)],
            incoming: [BeatOnset(seconds: 0.20, strength: 0.6)],
            duration: 10, requestedFade: 2
        )
        check(plan != nil, "synthetic drum attacks permit small alignment")
        if let plan {
            check(abs(plan.outgoingStart - 8.10) < 0.001 && abs(plan.incomingStart - 0.20) < 0.001, "beat offsets retained")
            check(abs(plan.fadeSeconds - 1.90) < 0.001, "plan fades to real end")
        }
        check(BeatOnsetAnalysis.plan(outgoing: [], incoming: [], duration: 120, requestedFade: 3) == nil, "missing attacks fall back")
        check(BeatOnsetAnalysis.plan(
            outgoing: [BeatOnset(seconds: .nan, strength: 0.5)],
            incoming: [BeatOnset(seconds: .infinity, strength: 0.5)], duration: 120, requestedFade: 3
        ) == nil, "nonfinite attacks rejected")
        check(BeatOnsetAnalysis.onsets(samples: pcm, sampleRate: 7_999).isEmpty, "invalid sample rate rejected")
        print("PASS: \(checks) transition defaults, envelopes, queue safety, attempts and synthetic beat checks")
    }
}
