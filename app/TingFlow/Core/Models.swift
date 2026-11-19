import Foundation

enum MusicPlatform: String, Codable, CaseIterable, Identifiable {
    case netease = "wy"
    case kugou = "kg"
    case emby = "emby"
    case subsonic = "subsonic"
    case local = "local"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .netease: return "网易云音乐"
        case .kugou: return "酷狗音乐"
        case .emby: return "Emby"
        case .subsonic: return "Navidrome / Subsonic"
        case .local: return "本地音乐"
        }
    }
}

struct Song: Identifiable, Codable, Hashable {
    let platform: MusicPlatform
    let platformID: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artworkURL: URL?
    var albumID: String?
    var hash: String?
    var highQualityHash: String?
    var losslessHash: String?
    var localFilename: String?
    var accountScope: String? = nil
    var id: String {
        if let accountScope { return "\(platform.rawValue):\(accountScope):\(platformID)" }
        return "\(platform.rawValue):\(platformID)"
    }
}

struct MusicPlaylist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var songIDs: [String] = []
    var createdAt: Date = Date()
}

enum AudioQuality: String, Codable, CaseIterable, Identifiable {
    case standard = "128k"
    case high = "320k"
    case lossless = "flac"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "标准"
        case .high: return "高品质"
        case .lossless: return "无损"
        }
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case sequential, all, one
    var next: RepeatMode {
        switch self {
        case .sequential: return .all
        case .all: return .one
        case .one: return .sequential
        }
    }
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    static func parse(_ input: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let offsetRegex = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let nsInput = input as NSString
        var offset: TimeInterval = 0
        if let match = offsetRegex?.firstMatch(in: input, range: NSRange(location: 0, length: nsInput.length)) {
            offset = (Double(nsInput.substring(with: match.range(at: 1))) ?? 0) / 1000
        }
        var values: [(time: TimeInterval, text: String, order: Int)] = []
        for line in input.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? "0" : ns.substring(with: fractionRange)
                let time = max(0, minutes * 60 + seconds + (Double(fraction) ?? 0) / pow(10, Double(fraction.count)) + offset)
                values.append((time, text, values.count))
            }
        }
        return values.sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            .enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}

enum MusicError: LocalizedError {
    case invalidURL, invalidResponse, http(Int), noSource, unsupported(String), invalidScript(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效，请使用 HTTPS 地址。"
        case .invalidResponse: return "服务返回的数据无法识别。"
        case .http(let code): return "服务返回 HTTP \(code)，请稍后重试。"
        case .noSource: return "尚未添加可用音源，请先在设置中导入你信任的洛雪 JS 音源。"
        case .unsupported(let text), .invalidScript(let text): return text
        }
    }
}
