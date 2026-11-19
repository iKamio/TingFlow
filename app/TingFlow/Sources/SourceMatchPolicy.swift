import Foundation

/// Fail-closed metadata matching; a title alone never authorizes a replacement.
enum SourceMatchPolicy {
    private static func normalized(_ input: String) -> String {
        input.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func artists(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet(charactersIn: "/&、,，;；"))
            .map(normalized).filter { !$0.isEmpty })
    }
    private static func editions(_ text: String) -> Set<String> {
        let value = normalized(text)
        return Set(["live", "remix", "dj", "instrumental", "伴奏", "翻唱", "现场", "acoustic", "remaster", "demo"]
            .filter { value.contains($0) })
    }
    static func matches(_ original: Song, _ candidate: Song) -> Bool {
        guard original.duration.isFinite, candidate.duration.isFinite,
              original.duration > 0, candidate.duration > 0, abs(original.duration - candidate.duration) <= 5,
              !normalized(original.title).isEmpty, normalized(original.title) == normalized(candidate.title),
              editions(original.title) == editions(candidate.title),
              !artists(original.artist).isDisjoint(with: artists(candidate.artist)) else { return false }
        return true
    }
    static func uniqueMatch(_ original: Song, candidates: [Song]) -> Song? {
        var ids = Set<String>()
        let filtered = candidates.filter { Self.matches(original, $0) && ids.insert($0.id).inserted }
        // Prefer refusing an ambiguous release over silently playing a different recording.
        return filtered.count == 1 ? filtered[0] : nil
    }
}
