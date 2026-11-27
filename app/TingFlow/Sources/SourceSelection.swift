import Foundation

/// Platform chips are catalog filters; these are independent parser choices.
enum SourceSelection: Equatable {
    case automatic
    case source(UUID)
    init(stored: String?) {
        if let stored, let id = UUID(uuidString: stored) { self = .source(id) }
        else { self = .automatic }
    }
    var storedValue: String? { if case .source(let id) = self { return id.uuidString }; return nil }
}

struct SourceAttempt: Identifiable, Equatable {
    enum Outcome: Equatable { case success, failed(SourceFailure) }
    let id = UUID()
    let sourceID: UUID
    let name: String
    let platform: MusicPlatform
    let outcome: Outcome
    var message: String {
        switch outcome {
        case .success: return "已返回可用地址"
        case .failed(let error): return error.localizedDescription
        }
    }
}

enum SourceSelectionPolicy {
    static func candidates(_ sources: [UserSource], selection: SourceSelection) -> [UserSource] {
        let enabled = sources.filter { $0.isEnabled && $0.isTrusted && !$0.allowedHosts.isEmpty }
        switch selection {
        case .automatic: return enabled
        case .source(let id): return enabled.filter { $0.id == id }
        }
    }
    static func failure(_ error: Error) -> SourceFailure {
        if error is CancellationError { return .cancelled }
        return error as? SourceFailure ?? .result
    }
}
