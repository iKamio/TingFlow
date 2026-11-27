import Foundation

enum SearchAggregationPolicy {
    static func platforms(emby: Bool, subsonic: Bool) -> [MusicPlatform] {
        [.netease, .kugou] + (emby ? [.emby] : []) + (subsonic ? [.subsonic] : [])
    }
    static func merged(_ buckets: [MusicPlatform: [Song]], platforms: [MusicPlatform]) -> [Song] {
        var result: [Song] = [], seen = Set<String>()
        let maximum = platforms.map { buckets[$0]?.count ?? 0 }.max() ?? 0
        for index in 0..<maximum {
            for platform in platforms {
                guard let bucket = buckets[platform], bucket.indices.contains(index) else { continue }
                let song = bucket[index]
                guard song.platform == platform, seen.insert(song.id).inserted else { continue }
                result.append(song)
            }
        }
        return result
    }
    /// UI and submission must use the same identity, including surrounding whitespace.
    static func matches(_ raw: String, submitted: String) -> Bool {
        !submitted.isEmpty && query(raw) == submitted
    }
    static func query(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}
