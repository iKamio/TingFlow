import Foundation

enum PlaybackFailure: LocalizedError {
    case source, network, range, format, redirect, http(Int)
    var errorDescription: String? {
        switch self {
        case .source: return "无法加载音源，请检查账号、音源和 HTTPS 配置。"
        case .network: return "音频连接中断，请检查网络后重试。"
        case .range: return "服务器未提供有效的分段音频响应，暂不支持此音源。"
        case .format: return "仅支持渐进式音频，不支持 HLS、DASH 或此音频格式。"
        case .redirect: return "鉴权音频不允许重定向，请配置最终 HTTPS 服务器地址。"
        case .http(let code): return "音频服务返回 HTTP \(code)，请检查授权或稍后重试。"
        }
    }
}

struct AudioByteRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64
    var length: Int64 { end - start + 1 }
    init(_ header: String) throws {
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { throw PlaybackFailure.range }
        let pair = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard pair.count == 2 else { throw PlaybackFailure.range }
        let bounds = pair[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        guard bounds.count == 2, let a = number(bounds[0]), let b = number(bounds[1]),
              let n = number(pair[1]), a <= b, b < n else { throw PlaybackFailure.range }
        start = a; end = b; total = n
    }
    func validate(start: Int64, end: Int64, knownTotal: Int64?) throws {
        guard self.start == start, self.end == min(end, total - 1),
              knownTotal == nil || knownTotal == total else { throw PlaybackFailure.range }
    }
}

enum PlaybackPolicy {
    static let chunk: Int64 = 512 * 1024
    static func validateURL(_ url: URL, local: Bool = false) throws {
        guard (local && url.isFileURL) || (url.scheme?.lowercased() == "https" && url.host?.isEmpty == false),
              url.user == nil, url.password == nil else { throw PlaybackFailure.source }
        guard !["m3u", "m3u8", "mpd"].contains(url.pathExtension.lowercased()) else { throw PlaybackFailure.format }
    }
    static func order(ids: [String], start: Int, shuffle: Bool) -> [Int] {
        guard shuffle, ids.indices.contains(start) else { return Array(ids.indices) }
        func hash(_ index: Int) -> UInt64 {
            (ids[index] + "#\(index)").utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        return [start] + ids.indices.filter { $0 != start }.sorted {
            let a = hash($0), b = hash($1)
            return a == b ? $0 < $1 : a < b
        }
    }
    static func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    static func metadata(_ value: String) -> String {
        let lower = value.lowercased()
        guard !["://", "token=", "api_key=", "apikey=", "password=", "bearer ", "authorization:", "x-emby-token"].contains(where: lower.contains) else { return "—" }
        return String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(256))
    }
}
