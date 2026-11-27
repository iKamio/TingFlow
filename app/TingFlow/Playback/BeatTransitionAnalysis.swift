import Foundation

struct BeatOnset: Equatable {
    let seconds: Double
    let strength: Double
}
struct BeatTransitionPlan: Equatable {
    let outgoingStart: Double
    let incomingStart: Double
    let fadeSeconds: Double
}
/// Energy/high-frequency positive flux over actual PCM; no catalog BPM, random values or network inference.
/// Deliberately detects attacks, not musical bars/tempo. Every sample and output count is bounded.
enum BeatOnsetAnalysis {
    static let maximumSeconds: Double = 12
    static let maximumShift: Double = 0.35
    static func onsets(samples: [Float], sampleRate: Double, offset: Double = 0) -> [BeatOnset] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate), offset.isFinite, offset >= 0 else { return [] }
        let window = max(1, Int(sampleRate * 0.01))
        let count = min(samples.count, Int(sampleRate * maximumSeconds)) / window
        guard count >= 8 else { return [] }
        var energy = [Double](), high = [Double]()
        energy.reserveCapacity(count); high.reserveCapacity(count)
        var previous: Double = 0
        for frame in 0..<count {
            var sum: Double = 0, difference: Double = 0
            for index in (frame * window)..<((frame + 1) * window) {
                let value = samples[index].isFinite ? min(1, max(-1, Double(samples[index]))) : 0
                sum += value * value; difference += (value - previous) * (value - previous); previous = value
            }
            energy.append(sqrt(sum / Double(window)))
            high.append(sqrt(difference / Double(window)))
        }
        var result = [BeatOnset](), last = -100.0
        for frame in 2..<(count - 1) {
            let baselineStart = max(0, frame - 20)
            let floor = energy[baselineStart..<frame].reduce(0, +) / Double(frame - baselineStart)
            let rise = max(0, energy[frame] - energy[frame - 1]) + 0.3 * max(0, high[frame] - high[frame - 1])
            let time = offset + Double(frame * window) / sampleRate
            guard energy[frame] > 0.025, energy[frame] > max(0.015, floor * 1.7),
                  rise > max(0.018, floor * 0.7), energy[frame] >= energy[frame + 1] * 0.65,
                  time - last >= 0.12 else { continue }
            result.append(BeatOnset(seconds: time, strength: min(1, rise))); last = time
            if result.count == 64 { break }
        }
        return result
    }
    /// Only a small leading offset and ±350 ms fade-start shift. Never time-stretch, invent BPM or skip an intro.
    static func plan(outgoing: [BeatOnset], incoming: [BeatOnset], duration: Double, requestedFade: Double) -> BeatTransitionPlan? {
        guard duration.isFinite, requestedFade.isFinite, requestedFade > 0,
              duration > PlaybackTransitionMath.boundedFade(requestedFade) + 2,
              let first = incoming.first(where: { $0.seconds.isFinite && $0.strength.isFinite && $0.seconds >= 0 && $0.seconds <= maximumShift && $0.strength > 0 }) else { return nil }
        let nominal = duration - PlaybackTransitionMath.boundedFade(requestedFade)
        guard let attack = outgoing.filter({ $0.seconds.isFinite && $0.strength.isFinite && $0.strength > 0 && abs($0.seconds - nominal) <= maximumShift })
            .min(by: { abs($0.seconds - nominal) < abs($1.seconds - nominal) }) else { return nil }
        let fade = duration - attack.seconds
        guard attack.seconds >= 0, fade.isFinite, fade >= 0.65, fade <= 8 + maximumShift else { return nil }
        return BeatTransitionPlan(outgoingStart: attack.seconds, incomingStart: first.seconds, fadeSeconds: fade)
    }
}
