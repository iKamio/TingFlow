import Foundation

@MainActor extension SourceStore {
    /// On-device provider routing, not api-enhanced's Node-only /song/url/match service.
    /// Only user-enabled JS receives requests; no built-in third-party audio endpoints.
    func resolveWithMatching(for song: Song, quality: AudioQuality) async throws -> PlaybackResource {
        let configuration = configurationID
        do { return try await playback(for: song, quality: quality) }
        catch {
            try Task.checkCancellation()
            if (error as? SourceFailure) == .cancelled || (error as? SourceFailure) == .busy { throw error }
            guard configurationID == configuration else { throw CancellationError() }
            guard song.platform == .netease, supports(.kugou), song.duration > 0,
                  !song.title.isEmpty, !song.artist.isEmpty else { throw error }
        }
        let results = try await CatalogClient().search(song.title + " " + song.artist, platform: .kugou)
        try Task.checkCancellation()
        guard configurationID == configuration else { throw CancellationError() }
        guard let matched = SourceMatchPolicy.uniqueMatch(song, candidates: results) else {
            throw MusicError.unsupported("启用音源没有解析到原曲；也未找到歌名、歌手、时长一致且无版本歧义的替代记录。")
        }
        var resource = try await playback(for: matched, quality: quality, preservingAttempts: true)
        resource.sourceLabel = "同曲匹配 · " + (resource.sourceLabel ?? "自定义音源")
        return resource
    }
}
