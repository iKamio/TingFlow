import Foundation
import CryptoKit

/// Total count is metadata, not a reason to reject a large music library.
struct EmbyCursor: Codable, Equatable {
    static let pageSize = 100
    private(set) var nextIndex = 0
    private(set) var total: Int?
    private(set) var hasMore = true
    private var fingerprints = Set<String>()

    mutating func accept(count: Int, reportedTotal: Int?, fingerprint: String? = nil) throws {
        guard (0...Self.pageSize).contains(count), reportedTotal.map({ $0 >= 0 }) ?? true else { throw EmbyFailure.response }
        let (next, overflow) = nextIndex.addingReportingOverflow(count)
        guard !overflow else { throw EmbyFailure.response }
        // A server ignoring StartIndex must not silently duplicate or loop forever.
        if count > 0, let fingerprint {
            guard !fingerprints.contains(fingerprint) else { throw EmbyFailure.paging }
        }
        if count == 0, let reportedTotal, reportedTotal > nextIndex { throw EmbyFailure.paging }
        if let reportedTotal { total = reportedTotal }
        else { total = nil }
        if count > 0, let fingerprint { fingerprints.insert(fingerprint) }
        nextIndex = next
        // Without a total, probe until an empty page: some servers cap pages below Limit.
        hasMore = count > 0 && (total.map { nextIndex < $0 } ?? true)
    }
    static func fingerprint(_ items: [EmbyItem], playlist: Bool = false) -> String? {
        guard !items.isEmpty else { return nil }
        let ids: [String]
        if playlist {
            // Equal songs may legitimately repeat; only playlist-entry IDs establish identity.
            let entries = items.compactMap(\.PlaylistItemId)
            guard entries.count == items.count, entries.allSatisfy({ !$0.isEmpty }) else { return nil }
            ids = entries
        } else {
            let entries = items.compactMap(\.Id)
            guard entries.count == items.count else { return nil }
            ids = entries
        }
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum EmbyLibraryKind: String, CaseIterable, Identifiable {
    case songs, albums, playlists
    var id: String { rawValue }
    var title: String {
        switch self { case .songs: return "歌曲"; case .albums: return "专辑"; case .playlists: return "歌单" }
    }
    var itemType: String {
        switch self { case .songs: return "Audio"; case .albums: return "MusicAlbum"; case .playlists: return "Playlist" }
    }
}

struct EmbyLibraryPageState {
    var cursor = EmbyCursor()
    var isLoading = false
    var isLoaded = false
    var retryFromStart = false
    var error: String?
    var ticket = UUID()
    var progressText: String {
        if !isLoaded { return isLoading ? "正在读取首批…" : "尚未读取" }
        let loaded = cursor.nextIndex
        if let total = cursor.total { return "已读取 \(loaded) / \(total) 条" + (cursor.hasMore ? " · 可继续加载" : "") }
        return "已读取 \(loaded) 条" + (cursor.hasMore ? " · 可继续加载" : " · 已到末尾")
    }
}

/// Page results carry the original query cursor and scoped metadata, never credentials.
struct EmbyTrackBatch {
    let songs: [Song]
    let cursor: EmbyCursor
    let accountScope: String
}
