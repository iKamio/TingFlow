import Foundation
import Combine

@MainActor
final class SubsonicStore: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountName = ""
    @Published private(set) var scopeID: String?
    @Published private(set) var albums: [SubsonicAlbum] = []
    @Published private(set) var playlists: [SubsonicPlaylist] = []
    @Published private(set) var songs: [Song] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let vaultKey = "subsonic.account.v1"
    private struct Snapshot: Codable {
        let version: Int
        let scope: String
        let albums: [SubsonicAlbum]
        let playlists: [SubsonicPlaylist]
    }
    private final class Context {
        let credential: SubsonicCredential
        let client: SubsonicClient
        let generation: UUID
        init(_ credential: SubsonicCredential, _ client: SubsonicClient, _ generation: UUID) {
            self.credential = credential; self.client = client; self.generation = generation
        }
    }

    private var generation = UUID()
    // Opaque local epoch only; never contains account or credential material.
    @Published private(set) var playbackContextID = UUID()
    private var auth: Context? {
        didSet { if oldValue !== auth { playbackContextID = UUID() } }
    }
    private var client: SubsonicClient?
    private var restoring: SubsonicCredential?
    private var albumOffset = 0
    private var albumHasMore = true
    private var cache: URL
    private let makeClient: (URL) -> SubsonicClient
    private let artworkCache = ServerArtworkCache()
    private var restorationBlocked = false

    init(cacheDirectory: URL? = nil, clientFactory: @escaping (URL) -> SubsonicClient = { SubsonicClient(base: $0) }) {
        makeClient = clientFactory
        cache = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
            .appendingPathComponent("TingFlow/Subsonic", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var directory = cache
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            if let data = try SecureVault.read(key: Self.vaultKey) {
                let record = try JSONDecoder().decode(SubsonicCredential.self, from: data)
                guard record.valid else { throw SubsonicFailure.storage }
                restoring = record
                let ticket = generation
                Task { [weak self] in await self?.restore(record, ticket: ticket) }
            }
        } catch {
            errorMessage = SubsonicFailure.storage.localizedDescription
        }
    }

    var serviceLabel: String {
        if let auth { return auth.credential.navidrome ? "Navidrome" : "Subsonic" }
        if let restoring { return restoring.navidrome ? "Navidrome" : "Subsonic" }
        return "Subsonic"
    }

    var artworkService: ServerArtworkDiagnostic.Service {
        if let auth { return auth.credential.navidrome ? .navidrome : .subsonic }
        if let restoring { return restoring.navidrome ? .navidrome : .subsonic }
        return .subsonic
    }

    func signIn(baseURL: String, username: String, password: String, navidrome: Bool) async {
        let ticket = beginNewSession()
        do {
            do { try SecureVault.remove(key: Self.vaultKey) } catch { throw SubsonicFailure.storage }
            let base = try SubsonicPolicy.base(baseURL)
            guard SubsonicPolicy.validUsername(username) else { throw SubsonicFailure.authentication }
            let salt = try SubsonicPolicy.salt()
            let record = SubsonicCredential(server: base, username: username, token: SubsonicPolicy.token(password: password, salt: salt), salt: salt, navidrome: navidrome)
            let http = makeClient(base); client = http
            isLoading = true; errorMessage = nil
            let response = try await http.request("ping", credential: record)
            _ = response
            try current(ticket, http: http)
            try SecureVault.save(JSONEncoder().encode(record), key: Self.vaultKey)
            activate(record, client: http, ticket: ticket)
            await refresh()
        } catch {
            guard generation == ticket else { return }
            isLoading = false
            if !(error is CancellationError) { errorMessage = SubsonicFailure.safe(error).localizedDescription }
            client?.cancel(); client = nil
        }
    }

    private func restore(_ record: SubsonicCredential, ticket: UUID) async {
        guard generation == ticket, auth == nil, !restorationBlocked else { return }
        let http = makeClient(record.server); client = http; isLoading = true
        do {
            _ = try await http.request("ping", credential: record)
            try current(ticket, http: http)
            activate(record, client: http, ticket: ticket)
            loadSnapshot(record.scope)
            await refresh()
        } catch {
            guard generation == ticket else { return }
            if case .authentication = SubsonicFailure.safe(error) { try? SecureVault.remove(key: Self.vaultKey) }
            http.cancel(); client = nil; isLoading = false
            if !(error is CancellationError) { errorMessage = SubsonicFailure.safe(error).localizedDescription }
        }
    }

    private func beginNewSession() -> UUID {
        generation = UUID(); artworkCache.clear(); client?.cancel(); client = nil; auth = nil; restoring = nil
        isSignedIn = false; accountName = ""; scopeID = nil
        albums = []; playlists = []; songs = []; errorMessage = nil; isLoading = false
        restorationBlocked = true
        return generation
    }
    private func current(_ ticket: UUID, http: SubsonicClient) throws {
        try Task.checkCancellation()
        guard generation == ticket, client === http else { throw CancellationError() }
    }
    private func activate(_ record: SubsonicCredential, client: SubsonicClient, ticket: UUID) {
        guard generation == ticket else { return }
        auth = Context(record, client, ticket); self.client = client; restoring = nil; restorationBlocked = false
        accountName = record.username; scopeID = record.scope; isSignedIn = true
        errorMessage = nil; isLoading = false; albumOffset = 0; albumHasMore = true
    }

    func refresh() async {
        guard let context = auth, !isLoading else { return }
        artworkCache.clear()
        isLoading = true; errorMessage = nil
        do {
            let albumResponse = try await context.client.request("getAlbumList2", credential: context.credential,
                parameters: [URLQueryItem(name: "type", value: "newest"), URLQueryItem(name: "size", value: "100"), URLQueryItem(name: "offset", value: "0")])
            try current(context)
            guard let albumList = albumResponse.albumList2 else { throw SubsonicFailure.response }
            let albumRecords = albumList.album ?? []
            guard albumRecords.count <= SubsonicPolicy.pageSize else { throw SubsonicFailure.response }
            let loadedAlbums = albumRecords.compactMap { album($0, scope: context.credential.scope) }
            albums = loadedAlbums; albumOffset = albumRecords.count; albumHasMore = albumRecords.count == SubsonicPolicy.pageSize
            let playlistResponse = try await context.client.request("getPlaylists", credential: context.credential)
            try current(context)
            guard let lists = playlistResponse.playlists else { throw SubsonicFailure.response }
            playlists = (lists.playlist ?? []).compactMap { playlist($0, scope: context.credential.scope) }
            songs = []
            saveSnapshot(context)
            isLoading = false
        } catch {
            guard auth === context else { return }
            isLoading = false
            if !(error is CancellationError) { errorMessage = SubsonicFailure.safe(error).localizedDescription }
        }
    }

    private func current(_ context: Context) throws {
        try Task.checkCancellation()
        guard auth === context, generation == context.generation else { throw CancellationError() }
    }

    func loadMoreAlbums() async {
        guard let context = auth, albumHasMore, !isLoading else { return }
        isLoading = true; errorMessage = nil
        do {
            let response = try await context.client.request("getAlbumList2", credential: context.credential,
                parameters: [URLQueryItem(name: "type", value: "newest"), URLQueryItem(name: "size", value: "100"),
                             URLQueryItem(name: "offset", value: String(albumOffset))])
            try current(context)
            guard let albumList = response.albumList2 else { throw SubsonicFailure.response }
            let records = albumList.album ?? []
            guard records.count <= SubsonicPolicy.pageSize else { throw SubsonicFailure.response }
            let page = records.compactMap { album($0, scope: context.credential.scope) }
            var seen = Set(albums.map(\.id))
            let unique = page.filter { seen.insert($0.id).inserted }
            guard records.isEmpty || !unique.isEmpty else { throw SubsonicFailure.response }
            albums.append(contentsOf: unique)
            albumOffset += records.count
            albumHasMore = records.count == SubsonicPolicy.pageSize
            saveSnapshot(context); isLoading = false
        } catch {
            guard auth === context else { return }
            isLoading = false
            if !(error is CancellationError) { errorMessage = SubsonicFailure.safe(error).localizedDescription }
        }
    }

    func artwork(for album: SubsonicAlbum, pixels: Int = 320) async throws -> Data? {
        do { return try await artworkResult(for: album, pixels: pixels).data }
        catch let failure as ServerArtworkDiagnosticFailure { throw SubsonicFailure.artwork(failure.diagnostic) }
    }
    func artwork(for playlist: SubsonicPlaylist, pixels: Int = 320) async throws -> Data? {
        do { return try await artworkResult(for: playlist, pixels: pixels).data }
        catch let failure as ServerArtworkDiagnosticFailure { throw SubsonicFailure.artwork(failure.diagnostic) }
    }
    func artworkResult(for album: SubsonicAlbum, pixels: Int = 320) async throws -> ServerArtworkResult {
        try await collectionArtworkResult(id: album.id, revision: album.coverArtID, scope: album.accountScope, playlist: false, pixels: pixels)
    }
    func artworkResult(for playlist: SubsonicPlaylist, pixels: Int = 320) async throws -> ServerArtworkResult {
        try await collectionArtworkResult(id: playlist.id, revision: playlist.coverArtID, scope: playlist.accountScope, playlist: true, pixels: pixels)
    }
    private func verifyArtwork(_ context: Context, id: String, revision: String?, scope: String, playlist: Bool) throws {
        try current(context)
        guard isSignedIn, scopeID == scope, scope == context.credential.scope, SubsonicPolicy.validID(id),
              revision.map(SubsonicPolicy.validArtworkID) != false else { throw SubsonicFailure.account }
        if playlist {
            guard let item = playlists.first(where: { $0.id == id }), item.accountScope == scope,
                  item.coverArtID == revision else { throw SubsonicFailure.account }
        } else {
            guard let item = albums.first(where: { $0.id == id }), item.accountScope == scope,
                  item.coverArtID == revision else { throw SubsonicFailure.account }
        }
    }
    private func collectionArtworkResult(id: String, revision: String?, scope: String, playlist: Bool, pixels: Int) async throws -> ServerArtworkResult {
        try Task.checkCancellation()
        var local = ServerArtworkDiagnostic(service: artworkService, pixels: pixels)
        local.origin = .metadata
        let context: Context
        do {
            context = try self.context(for: scope)
            try verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
        } catch is CancellationError { throw CancellationError() }
        catch {
            local.issue = auth == nil ? .signedOut : .invalidContext
            throw ServerArtworkDiagnosticFailure(diagnostic: local)
        }
        guard let revision else {
            local.issue = .missingID
            return ServerArtworkResult(data: nil, diagnostic: local)
        }
        let size = ServerArtworkCache.pixels(pixels)
        let key = ServerArtworkCache.Key(scope: "subsonic:" + scope + (playlist ? ":playlist" : ":album"), id: id, revision: SubsonicPolicy.artworkRevision(revision), pixels: size)
        // This observation belongs only to the loader started by this call.
        // Cache hits/shared flights must not reuse another request's HTTP/code.
        var observation: ServerArtworkDiagnostic?
        do {
            let data = try await artworkCache.data(for: key) { [weak self] in
                guard let self else { throw CancellationError() }
                try self.verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
                let result = try await context.client.artworkResult(id: revision, credential: context.credential, pixels: size)
                try self.verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
                observation = result.diagnostic
                return result.data
            }
            try verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
            var diagnostic = observation ?? ServerArtworkDiagnostic(service: context.credential.navidrome ? .navidrome : .subsonic, pixels: size)
            if observation == nil {
                diagnostic.origin = .cacheOrShared
                diagnostic.stage = .completed
                diagnostic.issue = data == nil ? .notFound : .none
                diagnostic.bytesReceived = data?.count ?? 0
            }
            return ServerArtworkResult(data: data, diagnostic: diagnostic)
        } catch {
            try current(context)
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? ServerArtworkDiagnosticFailure { throw failure }
            local.issue = (error as? SubsonicFailure) == .account ? .invalidContext : .unknown
            throw ServerArtworkDiagnosticFailure(diagnostic: local)
        }
    }

    func tracks(in album: SubsonicAlbum) async throws -> [Song] {
        let context = try context(for: album.accountScope)
        let response = try await context.client.request("getAlbum", credential: context.credential,
                                                        parameters: [URLQueryItem(name: "id", value: album.id)])
        try current(context)
        guard response.album?.id == album.id else { throw SubsonicFailure.response }
        return response.album?.song?.compactMap { $0.song(scope: context.credential.scope) } ?? []
    }

    func tracks(in playlist: SubsonicPlaylist) async throws -> [Song] {
        let context = try context(for: playlist.accountScope)
        let response = try await context.client.request("getPlaylist", credential: context.credential,
                                                        parameters: [URLQueryItem(name: "id", value: playlist.id)])
        try current(context)
        guard response.playlist?.id == playlist.id else { throw SubsonicFailure.response }
        // Do not de-duplicate: playlist entry order and duplicate entries are meaningful.
        return response.playlist?.entry?.compactMap { $0.song(scope: context.credential.scope) } ?? []
    }

    func search(_ query: String) async throws -> [Song] {
        let context = try context()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1024 else { return [] }
        let response = try await context.client.request("search3", credential: context.credential,
            parameters: [URLQueryItem(name: "query", value: text), URLQueryItem(name: "songCount", value: "100"),
                         URLQueryItem(name: "songOffset", value: "0"), URLQueryItem(name: "artistCount", value: "0"),
                         URLQueryItem(name: "albumCount", value: "0")])
        try current(context)
        let result = response.searchResult3?.song?.compactMap { $0.song(scope: context.credential.scope) } ?? []
        songs = result
        return result
    }

    func playback(for song: Song) async throws -> PlaybackResource {
        let context = try context()
        guard song.platform == .subsonic, song.accountScope == context.credential.scope,
              SubsonicPolicy.validID(song.platformID) else { throw SubsonicFailure.account }
        try current(context)
        return try context.client.playback(id: song.platformID, credential: context.credential)
    }

    func signOut() async {
        generation = UUID(); artworkCache.clear(); client?.cancel(); client = nil; auth = nil; restoring = nil; restorationBlocked = true
        isSignedIn = false; accountName = ""; scopeID = nil
        albums = []; playlists = []; songs = []; isLoading = false; errorMessage = nil
        albumOffset = 0; albumHasMore = true
        do { try SecureVault.remove(key: Self.vaultKey) }
        catch { errorMessage = "本机已停止会话，但安全凭据清除失败；请解锁设备后再次退出。" }
        do {
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var url = cache; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { errorMessage = SubsonicFailure.storage.localizedDescription }
    }

    private func context() throws -> Context {
        guard let context = auth else { throw SubsonicFailure.signedOut }
        return context
    }
    private func context(for scope: String) throws -> Context {
        let context = try context()
        guard context.credential.scope == scope else { throw SubsonicFailure.account }
        return context
    }
    private func album(_ record: SubsonicRecord, scope: String) -> SubsonicAlbum? {
        guard SubsonicPolicy.validID(record.id) else { return nil }
        return SubsonicAlbum(id: record.id, name: record.name ?? record.album ?? "未知专辑",
                             artist: record.artist, accountScope: scope,
                             coverArtID: record.coverArt.flatMap { SubsonicPolicy.validArtworkID($0) ? $0 : nil }, songCount: record.songCount)
    }
    private func playlist(_ record: SubsonicRecord, scope: String) -> SubsonicPlaylist? {
        guard SubsonicPolicy.validID(record.id) else { return nil }
        return SubsonicPlaylist(id: record.id, name: record.name ?? "未命名歌单",
                                artist: record.artist, accountScope: scope,
                             coverArtID: record.coverArt.flatMap { SubsonicPolicy.validArtworkID($0) ? $0 : nil }, songCount: record.songCount)
    }
    private func snapshotURL(_ scope: String) -> URL {
        cache.appendingPathComponent(scope.replacingOccurrences(of: ":", with: "-") + ".json")
    }
    private func loadSnapshot(_ scope: String) {
        guard let data = try? Data(contentsOf: snapshotURL(scope)),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.version == 1,
              saved.scope == scope else { return }
        albums = saved.albums.filter { $0.accountScope == scope }
        playlists = saved.playlists.filter { $0.accountScope == scope }
        albumOffset = albums.count; albumHasMore = true
    }
    private func saveSnapshot(_ context: Context) {
        guard auth === context else { return }
        let snapshot = Snapshot(version: 1, scope: context.credential.scope,
                                albums: albums, playlists: playlists)
        do {
            let data = try JSONEncoder().encode(snapshot)
            #if os(iOS)
            try data.write(to: snapshotURL(context.credential.scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: snapshotURL(context.credential.scope), options: .atomic)
            #endif
        } catch { errorMessage = SubsonicFailure.storage.localizedDescription }
    }
}
