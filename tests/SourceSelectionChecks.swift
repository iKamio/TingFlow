import Foundation

@main struct SourceSelectionChecks {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); count += 1 }
        func source(_ name: String, enabled: Bool = true, trusted: Bool = true) -> UserSource {
            var value = UserSource(id: UUID(), sha256: String(repeating: "a", count: 64), name: name, version: "1", author: "fixture", description: "")
            value.isEnabled = enabled; value.isTrusted = trusted
            value.allowedHosts = trusted ? ["music-api.example.invalid"] : []
            return value
        }
        let one = source("one"), two = source("two"), disabled = source("disabled", enabled: false), untrusted = source("untrusted", trusted: false)
        let values = [one, disabled, two, untrusted]
        check(SourceSelectionPolicy.candidates(values, selection: .automatic).map(\.id) == [one.id, two.id], "automatic preserves only enabled trusted sources in order")
        check(SourceSelectionPolicy.candidates(values, selection: .source(two.id)).map(\.id) == [two.id], "manual choice is exactly one parser")
        check(SourceSelectionPolicy.candidates(values, selection: .source(disabled.id)).isEmpty, "manual disabled source does not silently fallback")
        check(SourceSelectionPolicy.candidates(values, selection: .source(untrusted.id)).isEmpty, "untrusted source never executes")
        check(SourceSelection(stored: two.id.uuidString) == .source(two.id), "restore UUID selection")
        check(SourceSelection(stored: "unknown") == .automatic, "invalid saved selection fails safe")
        check(SourceSelection.automatic.storedValue == nil, "automatic selection has no identity")
        check(SourceSelection.source(two.id).storedValue == two.id.uuidString, "manual selection stores only UUID")
        check(SourceAttempt(sourceID: one.id, name: one.name, platform: .kugou, outcome: .failed(.permission)).message == SourceFailure.permission.localizedDescription,
              "error feedback is fixed local text")
        print("PASS: \(count) manual/automatic parser selection checks")
    }
}
