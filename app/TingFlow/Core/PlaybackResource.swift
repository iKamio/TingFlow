import Foundation

/// In-memory only. Never Codable: playback URLs and headers may be credentials.
struct PlaybackResource {
    let url: URL
    var headers: [String: String] = [:]
    var mimeType: String? = nil
    var isPreview: Bool = false
    var displayQuality: String = "原始音频"
    var requiresResourceLoader: Bool = false
    var sourceLabel: String? = nil
    /// Only populated after an authenticated, original Netease response; never persisted or sent to JS.
    var neteaseHistoryScope: String? = nil
}
