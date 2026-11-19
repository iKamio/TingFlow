import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    private struct Snapshot: Codable {
        var schemaVersion = 1
        var songs: [String: Song] = [:]
        var favorites: [String] = []
        var recent: [String] = []
        var playlists: [MusicPlaylist] = []
    }
    @Published private(set) var songs: [String: Song] = [:]
    @Published private(set) var favorites: [String] = []
    @Published private(set) var recent: [String] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var activeScopes: Set<String> = []
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TingFlow", isDirectory: true)
        fileURL = base.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
                guard snapshot.schemaVersion == 1 else {
                    persistenceError = "音乐库格式较新，请升级 App 后重试。"
                    return
                }
                songs = snapshot.songs
                favorites = snapshot.favorites.filter { snapshot.songs[$0] != nil }
                recent = snapshot.recent.filter { snapshot.songs[$0] != nil }
                playlists = snapshot.playlists
            }
        } catch {
            // Do not silently replace a damaged library with an empty snapshot.
            persistenceError = "音乐库读取失败，原文件已保留。"
        }
    }

    func activateScopes(_ scopes: Set<String>) { activeScopes = scopes }
    func visibleSong(_ id: String) -> Song? {
        guard let song = songs[id] else { return nil }
        if let scope = song.accountScope, !activeScopes.contains(scope) { return nil }
        return song
    }
    func isFavorite(_ song: Song) -> Bool { favorites.contains(song.id) }
    func favoriteSongs() -> [Song] { favorites.compactMap { visibleSong($0) } }
    func recentSongs() -> [Song] { recent.compactMap { visibleSong($0) } }
    func toggleFavorite(_ song: Song) {
        guard persistenceError == nil else { return }
        songs[song.id] = song
        if favorites.contains(song.id) { favorites.removeAll { $0 == song.id } }
        else { favorites.insert(song.id, at: 0) }
        save()
    }
    func recordPlayed(_ song: Song) {
        guard persistenceError == nil else { return }
        songs[song.id] = song
        recent.removeAll { $0 == song.id }
        recent.insert(song.id, at: 0)
        recent = Array(recent.prefix(100))
        save()
    }
    func createPlaylist(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, persistenceError == nil else { return }
        playlists.append(MusicPlaylist(name: String(name.prefix(80))))
        save()
    }
    func add(_ song: Song, to playlistID: UUID) {
        guard persistenceError == nil, let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        songs[song.id] = song
        if !playlists[index].songIDs.contains(song.id) { playlists[index].songIDs.append(song.id) }
        save()
    }
    func deletePlaylist(_ id: UUID) {
        guard persistenceError == nil else { return }
        playlists.removeAll { $0.id == id }
        save()
    }
    func removeAccountScope(_ scope: String) {
        guard persistenceError == nil else { return }
        let removed = Set(songs.values.filter { $0.accountScope == scope }.map(\.id))
        for id in removed { songs.removeValue(forKey: id) }
        favorites.removeAll { removed.contains($0) }
        recent.removeAll { removed.contains($0) }
        for index in playlists.indices { playlists[index].songIDs.removeAll { removed.contains($0) } }
        save()
    }
    private func save() {
        do {
            let snapshot = Snapshot(songs: songs, favorites: favorites, recent: recent, playlists: playlists)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            persistenceError = "音乐库保存失败，请检查可用空间；磁盘上的旧文件未主动删除。"
        }
    }
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [Song] = []
    @Published private(set) var failures: [MusicPlatform: String] = [:]
    @Published private(set) var isSearching = false
    var embySearch: (@MainActor (String) async throws -> [Song])?
    var subsonicSearch: (@MainActor (String) async throws -> [Song])?
    private let catalog = CatalogClient()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func clear() {
        task?.cancel()
        generation = UUID()
        results = []; failures = [:]; isSearching = false
    }
    func search(platforms: [MusicPlatform] = [.netease, .kugou]) {
        task?.cancel()
        generation = UUID()
        let token = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; failures = [:]; isSearching = false; return }
        isSearching = true
        failures = [:]
        task = Task { [weak self] in
            guard let self else { return }
            var collected: [Song] = []
            var errors: [MusicPlatform: String] = [:]
            await withTaskGroup(of: (MusicPlatform, [Song], String?).self) { group in
                for platform in platforms {
                    group.addTask { [catalog = self.catalog, embySearch = self.embySearch, subsonicSearch = self.subsonicSearch] in
                        do {
                            if platform == .emby {
                                guard let embySearch else { return (platform, [], "请先连接 Emby 服务器。") }
                                return (platform, try await embySearch(text), nil)
                            }
                            if platform == .subsonic {
                                guard let subsonicSearch else { return (platform, [], "请先连接 Navidrome / Subsonic 服务器。") }
                                return (platform, try await subsonicSearch(text), nil)
                            }
                            return (platform, try await catalog.search(text, platform: platform), nil)
                        }
                        catch is CancellationError { return (platform, [], nil) }
                        catch { return (platform, [], "请求失败，请检查连接或重新登录后重试。") }
                    }
                }
                for await (platform, songs, error) in group {
                    collected.append(contentsOf: songs)
                    if let error { errors[platform] = error }
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            var seen = Set<String>()
            // Preserve per-platform ranking and interleave the two sources.
            let buckets = platforms.map { p in collected.filter { $0.platform == p } }
            var merged: [Song] = []
            for index in 0..<(buckets.map(\.count).max() ?? 0) {
                for bucket in buckets where index < bucket.count {
                    if seen.insert(bucket[index].id).inserted { merged.append(bucket[index]) }
                }
            }
            self.results = merged
            self.failures = errors
            self.isSearching = false
        }
    }
}
