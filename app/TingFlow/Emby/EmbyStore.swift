import Foundation
import Combine

@MainActor
final class EmbyStore: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountName = ""
    @Published private(set) var scopeID: String?
    @Published private(set) var songs: [Song] = []
    @Published private(set) var albums: [EmbyAlbum] = []
    @Published private(set) var playlists: [EmbyPlaylist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var libraryPages: [EmbyLibraryKind: EmbyLibraryPageState] = [:]
    @Published private(set) var searchNotice: String?
    @Published private(set) var playbackDiagnostic: String?

    private struct Credential: Codable {
        let base: URL; let server: String; let user: String; let name: String
        let token: String; let device: String
        var scope: String { EmbyAddress.scope(base: base, server: server, user: user) }
    }
    private final class Context {
        let credential: Credential; let client: EmbyClient; let generation: UUID
        init(_ credential: Credential, _ client: EmbyClient, _ generation: UUID) {
            self.credential = credential; self.client = client; self.generation = generation
        }
    }
    private struct Snapshot: Codable {
        let version: Int; let scope: String
        let songs: [Song]; let albums: [EmbyAlbum]; let playlists: [EmbyPlaylist]
        let cursors: [String: EmbyCursor]?
    }
    private static let vaultKey = "emby.account.v1"
    private var generation = UUID()
    private var refreshID = UUID()
    private var searchID = UUID()
    private var client: EmbyClient?
    private var auth: Context?
    private var restoring: Credential?
    private let device: String
    private let cache: URL
    private let makeClient: (URL, String) -> EmbyClient
    private let artworkCache = ServerArtworkCache()

    init(cacheDirectory: URL? = nil, clientFactory: @escaping (URL, String) -> EmbyClient = { EmbyClient(base: $0, device: $1) }) {
        makeClient = clientFactory
        let key = "emby.installation.v1"
        let saved = UserDefaults.standard.string(forKey: key)
        device = saved.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        UserDefaults.standard.set(device, forKey: key)
        cache = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TingFlow/Emby", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var directory = cache
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            // Read the credential synchronously, before starting any network task.
            if let data = try SecureVault.read(key: Self.vaultKey) {
                let record = try JSONDecoder().decode(Credential.self, from: data)
                guard try EmbyAddress.base(record.base.absoluteString) == record.base,
                      EmbyAddress.validID(record.user), EmbyAddress.validID(record.server),
                      EmbyAddress.validToken(record.token), UUID(uuidString: record.device) != nil
                else { throw EmbyFailure.response }
                restoring = record
                let ticket = generation
                Task { [weak self] in await self?.restore(record, ticket: ticket) }
            }
        } catch { errorMessage = EmbyFailure.storage.localizedDescription }
    }

    func signIn(baseURL: String, username: String, password: String) async {
        do {
            let base = try EmbyAddress.base(baseURL)
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EmbyFailure.response
            }
            guard clearLocal() else { return }
            let ticket = generation
            let http = makeClient(base, device); client = http
            isLoading = true; errorMessage = nil
            do {
                let result = try http.decode(EmbyLogin.self, await http.data(
                    ["Users", "AuthenticateByName"], body: ["Username": username, "Pw": password], post: true))
                try check(ticket, http)
                guard let user = result.User?.Id, EmbyAddress.validID(user),
                      let token = result.AccessToken, EmbyAddress.validToken(token),
                      let server = result.ServerId, EmbyAddress.validID(server) else { throw EmbyFailure.response }
                let record = Credential(base: base, server: server, user: user,
                                        name: result.User?.Name ?? username, token: token, device: device)
                try await validate(record, http: http)
                try check(ticket, http)
                do { try SecureVault.save(JSONEncoder().encode(record), key: Self.vaultKey) }
                catch { throw EmbyFailure.storage }
                activate(record, http: http, ticket: ticket)
                await refresh()
            } catch {
                guard generation == ticket, client === http else { return }
                isLoading = false
                if !(error is CancellationError) { errorMessage = safe(error).localizedDescription }
                http.cancel(); client = nil
            }
        } catch { errorMessage = safe(error).localizedDescription }
    }

    private func restore(_ record: Credential, ticket: UUID) async {
        guard generation == ticket, auth == nil else { return }
        let http = makeClient(record.base, record.device); client = http
        isLoading = true
        do {
            try await validate(record, http: http)
            try check(ticket, http)
            activate(record, http: http, ticket: ticket)
            await refresh()
        } catch {
            guard generation == ticket, client === http else { return }
            if case EmbyFailure.unauthorized = error { _ = clearLocal() }
            http.cancel(); client = nil; isLoading = false
            if !(error is CancellationError) { errorMessage = safe(error).localizedDescription }
        }
    }

    private func validate(_ record: Credential, http: EmbyClient) async throws {
        let user = try http.decode(EmbyUser.self, await http.data(["Users", record.user],
                                                                   token: record.token, user: record.user))
        guard user.Id == record.user else { throw EmbyFailure.unauthorized }
        let server = try http.decode(EmbyServer.self, await http.data(["System", "Info", "Public"]))
        guard server.Id == record.server else { throw EmbyFailure.unauthorized }
    }

    private func activate(_ record: Credential, http: EmbyClient, ticket: UUID) {
        auth = Context(record, http, ticket); restoring = nil
        accountName = record.name; scopeID = record.scope; isSignedIn = true
        errorMessage = nil; isLoading = false
        if let data = try? Data(contentsOf: snapshotURL(record.scope)),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           [1, 2].contains(saved.version), saved.scope == record.scope {
            songs = saved.songs.filter { $0.platform == .emby && $0.accountScope == record.scope }
            albums = saved.albums.filter { $0.accountScope == record.scope }
            playlists = saved.playlists.filter { $0.accountScope == record.scope }
            for kind in EmbyLibraryKind.allCases {
                if let cursor = saved.cursors?[kind.rawValue] {
                    var state = EmbyLibraryPageState(); state.cursor = cursor; state.isLoaded = true
                    libraryPages[kind] = state
                }
            }
        }
    }

    func refresh() async {
        guard let context = auth else { return }
        artworkCache.clear()
        let ticket = UUID(); refreshID = ticket; isLoading = true; errorMessage = nil
        // Only one bounded page per type. Each successful type publishes immediately.
        for kind in EmbyLibraryKind.allCases {
            guard auth === context, refreshID == ticket, !Task.isCancelled else { break }
            await loadLibraryPage(kind, context: context, reset: true, refresh: ticket)
        }
        if auth === context, refreshID == ticket {
            isLoading = false
            // A cancelled refresh must not leave a stale loading flag behind.
            for kind in EmbyLibraryKind.allCases {
                if var state = libraryPages[kind], state.isLoading { state.isLoading = false; libraryPages[kind] = state }
            }
        }
    }

    func pageState(_ kind: EmbyLibraryKind) -> EmbyLibraryPageState { libraryPages[kind] ?? EmbyLibraryPageState() }
    func loadMore(_ kind: EmbyLibraryKind) async {
        guard let context = auth, !isLoading else { return }
        let state = pageState(kind)
        guard !state.isLoading, !state.isLoaded || state.cursor.hasMore || state.error != nil else { return }
        await loadLibraryPage(kind, context: context, reset: !state.isLoaded || state.retryFromStart, refresh: refreshID)
    }
    private func loadLibraryPage(_ kind: EmbyLibraryKind, context: Context, reset: Bool, refresh: UUID) async {
        var state = pageState(kind)
        if !reset && state.isLoading { return }
        let ticket = UUID()
        state.ticket = ticket; state.isLoading = true; state.error = nil
        libraryPages[kind] = state
        do {
            let oldCursor = reset ? EmbyCursor() : state.cursor
            var query = [URLQueryItem(name: "Recursive", value: "true"),
                         URLQueryItem(name: "IncludeItemTypes", value: kind.itemType),
                         URLQueryItem(name: "SortBy", value: "SortName"), URLQueryItem(name: "SortOrder", value: "Ascending")]
            if kind != .songs {
                query += [URLQueryItem(name: "Fields", value: "ChildCount"),
                          URLQueryItem(name: "EnableImages", value: "true"),
                          URLQueryItem(name: "EnableImageTypes", value: "Primary")]
            }
            let batch = try await page(context, path: ["Users", context.credential.user, "Items"], query: query, cursor: oldCursor)
            try current(context)
            guard refreshID == refresh, libraryPages[kind]?.ticket == ticket else { return }
            let scope = context.credential.scope
            switch kind {
            case .songs:
                let loaded = batch.items.compactMap { $0.song(scope: scope) }
                songs = merge(reset ? [] : songs, loaded, id: { $0.id })
            case .albums:
                let loaded = batch.items.compactMap { item -> EmbyAlbum? in
                    guard item.Type == "MusicAlbum", let id = item.Id, EmbyAddress.validID(id) else { return nil }
                    return EmbyAlbum(id: id, name: item.Name ?? "未知专辑", accountScope: scope,
                                     artist: item.collectionArtist, songCount: item.ChildCount, primaryImageTag: item.primaryImageTag)
                }
                albums = merge(reset ? [] : albums, loaded, id: { $0.id })
            case .playlists:
                let loaded = batch.items.compactMap { item -> EmbyPlaylist? in
                    guard item.Type == "Playlist", item.MediaType == "Audio", let id = item.Id,
                          EmbyAddress.validID(id) else { return nil }
                    return EmbyPlaylist(id: id, name: item.Name ?? "未命名歌单", accountScope: scope,
                                        artist: item.collectionArtist, songCount: item.ChildCount, primaryImageTag: item.primaryImageTag)
                }
                playlists = merge(reset ? [] : playlists, loaded, id: { $0.id })
            }
            state.cursor = batch.cursor; state.isLoaded = true; state.isLoading = false; state.retryFromStart = false
            libraryPages[kind] = state
            updateLibraryError()
            saveSnapshot(context)
        } catch {
            guard auth === context, refreshID == refresh, libraryPages[kind]?.ticket == ticket else { return }
            if Task.isCancelled || error is CancellationError {
                state.isLoading = false; libraryPages[kind] = state; return
            }
            if case EmbyFailure.unauthorized = error { _ = clearLocal(); errorMessage = EmbyFailure.unauthorized.localizedDescription; return }
            state.isLoading = false; state.error = safe(error).localizedDescription; state.retryFromStart = reset
            libraryPages[kind] = state
            updateLibraryError()
        }
    }
    private func merge<T>(_ old: [T], _ new: [T], id: (T) -> String) -> [T] {
        var seen = Set(old.map(id)), result = old
        for value in new where seen.insert(id(value)).inserted { result.append(value) }
        return result
    }
    private func updateLibraryError() {
        let messages = EmbyLibraryKind.allCases.compactMap { kind -> String? in
            guard let error = libraryPages[kind]?.error else { return nil }
            return "\(kind.title)：\(error)"
        }
        errorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    private func saveSnapshot(_ context: Context) {
        guard auth === context else { return }
        let cursors = Dictionary(uniqueKeysWithValues: libraryPages.compactMap { kind, state in
            state.isLoaded ? (kind.rawValue, state.cursor) : nil
        })
        do {
            try JSONEncoder().encode(Snapshot(version: 2, scope: context.credential.scope, songs: songs,
                                               albums: albums, playlists: playlists, cursors: cursors))
                .write(to: snapshotURL(context.credential.scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { errorMessage = EmbyFailure.storage.localizedDescription }
    }

    func search(_ query: String) async throws -> [Song] {
        let context = try context()
        let ticket = UUID(); searchID = ticket; searchNotice = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        do {
            let batch = try await page(context, path: ["Users", context.credential.user, "Items"], query: [
                URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "SearchTerm", value: text)
            ], cursor: EmbyCursor())
            try current(context)
            guard searchID == ticket else { throw CancellationError() }
            if batch.cursor.hasMore {
                let total = batch.cursor.total.map { " / \($0)" } ?? ""
                searchNotice = "Emby 先显示 \(batch.cursor.nextIndex)\(total) 条搜索结果；请细化关键词，或到音乐库逐页浏览。"
            }
            return batch.items.compactMap { $0.song(scope: context.credential.scope) }
        } catch { throw failure(error, context) }
    }

    func artwork(for album: EmbyAlbum, pixels: Int = 320) async throws -> Data? {
        try await collectionArtwork(id: album.id, revision: album.primaryImageTag, scope: album.accountScope, playlist: false, pixels: pixels)
    }
    func artwork(for playlist: EmbyPlaylist, pixels: Int = 320) async throws -> Data? {
        try await collectionArtwork(id: playlist.id, revision: playlist.primaryImageTag, scope: playlist.accountScope, playlist: true, pixels: pixels)
    }
    private func verifyArtwork(_ context: Context, id: String, revision: String?, scope: String, playlist: Bool) throws {
        try current(context)
        guard isSignedIn, scopeID == scope, scope == context.credential.scope, EmbyAddress.validID(id),
              revision.map(EmbyAddress.validImageTag) != false else { throw EmbyFailure.account }
        if playlist {
            guard let item = playlists.first(where: { $0.id == id }), item.accountScope == scope,
                  item.primaryImageTag == revision else { throw EmbyFailure.account }
        } else {
            guard let item = albums.first(where: { $0.id == id }), item.accountScope == scope,
                  item.primaryImageTag == revision else { throw EmbyFailure.account }
        }
    }
    private func collectionArtwork(id: String, revision: String?, scope: String, playlist: Bool, pixels: Int) async throws -> Data? {
        let context = try context()
        try verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
        let size = ServerArtworkCache.pixels(pixels)
        let key = ServerArtworkCache.Key(scope: "emby:" + scope, id: (playlist ? "playlist:" : "album:") + id, revision: revision, pixels: size)
        do {
            let data = try await artworkCache.data(for: key) { [weak self] in
                guard let self else { throw CancellationError() }
                try self.verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
                let result = try await context.client.artwork(item: id, tag: revision, token: context.credential.token, user: context.credential.user, pixels: size)
                try self.verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
                return result
            }
            try verifyArtwork(context, id: id, revision: revision, scope: scope, playlist: playlist)
            return data
        } catch { throw failure(error, context) }
    }

    func tracks(in album: EmbyAlbum, cursor: EmbyCursor = EmbyCursor()) async throws -> EmbyTrackBatch {
        let context = try context()
        guard album.accountScope == context.credential.scope, EmbyAddress.validID(album.id) else { throw EmbyFailure.account }
        do {
            let batch = try await page(context, path: ["Users", context.credential.user, "Items"], query: [
                URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "ParentId", value: album.id),
                URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber"),
                URLQueryItem(name: "SortOrder", value: "Ascending,Ascending")
            ], cursor: cursor)
            return EmbyTrackBatch(songs: batch.items.compactMap { $0.song(scope: context.credential.scope) },
                                  cursor: batch.cursor, accountScope: context.credential.scope)
        } catch { throw failure(error, context) }
    }

    func tracks(in playlist: EmbyPlaylist, cursor: EmbyCursor = EmbyCursor()) async throws -> EmbyTrackBatch {
        let context = try context()
        guard playlist.accountScope == context.credential.scope, EmbyAddress.validID(playlist.id) else { throw EmbyFailure.account }
        do {
            let batch = try await page(context, path: ["Playlists", playlist.id, "Items"], query: [], cursor: cursor, playlist: true)
            return EmbyTrackBatch(songs: batch.items.compactMap { $0.song(scope: context.credential.scope) },
                                  cursor: batch.cursor, accountScope: context.credential.scope)
        } catch { throw failure(error, context) }
    }

    func playback(for song: Song) async throws -> PlaybackResource {
        let context = try context(); let c = context.credential
        guard song.platform == .emby, song.accountScope == c.scope,
              EmbyAddress.validID(song.platformID) else { throw EmbyFailure.account }
        do {
            playbackDiagnostic = "正在读取 PlaybackInfo；诊断不会保存地址、路径或密钥。"
            let data = try await context.client.data(
                ["Items", song.platformID, "PlaybackInfo"], token: c.token, user: c.user,
                body: EmbyPlaybackPolicy.request(user: c.user), post: true)
            try current(context)
            playbackDiagnostic = EmbyPlaybackDiagnostic.make(data)
            let info = try context.client.decode(EmbyInfo.self, data)
            if let error = info.ErrorCode { throw error.failure }
            guard var sources = info.MediaSources else { throw EmbyFailure.missingSources }
            guard !sources.isEmpty else { throw EmbyFailure.emptySources }
            // One bounded same-account detail lookup, only when PlaybackInfo omitted
            // stream metadata. Never infer codec from an extension or a library row.
            if !sources.contains(where: { $0.progressiveFormat != nil }),
               sources.contains(where: { !$0.needsSession && !$0.directDenied && $0.MediaStreams?.isEmpty != false }) {
                let detailData = try await context.client.data(["Users", c.user, "Items", song.platformID],
                                                                token: c.token, user: c.user)
                try current(context)
                let detail = try context.client.decode(EmbyItem.self, detailData)
                guard detail.Id == song.platformID,
                      detail.Type == "Audio" || (detail.Type == nil && detail.MediaType == "Audio") else { throw EmbyFailure.response }
                sources = sources.map { $0.supplemented(by: detail, onlySource: sources.count == 1) }
                playbackDiagnostic = EmbyPlaybackDiagnostic.make(data) + "\n同曲目详情补充：\n" + EmbyPlaybackDiagnostic.make(detailData)
            }
            try current(context)
            let selected = try EmbyPlaybackPolicy.select(sources)
            return try EmbyPlaybackPolicy.resource(base: c.base, item: song.platformID, source: selected, token: c.token)
        } catch { throw failure(error, context) }
    }

    func signOut() async {
        let old = auth?.credential ?? restoring
        let cleaned = clearLocal() // All local removal happens BEFORE awaiting; never remove a newer login.
        let ticket = generation
        guard let old else { return }
        let http = makeClient(old.base, old.device)
        defer { http.cancel() }
        do { _ = try await http.data(["Sessions", "Logout"], token: old.token, user: old.user, post: true) }
        catch {
            if generation == ticket, cleaned { errorMessage = EmbyFailure.remoteLogout.localizedDescription }
        }
    }

    private struct ItemBatch {
        let items: [EmbyItem]
        let cursor: EmbyCursor
    }
    private func page(_ context: Context, path: [String], query: [URLQueryItem], cursor: EmbyCursor,
                      playlist: Bool = false) async throws -> ItemBatch {
        try current(context)
        let response = try context.client.decode(EmbyPage.self, await context.client.data(path,
            query: query + [URLQueryItem(name: "UserId", value: context.credential.user),
                           URLQueryItem(name: "StartIndex", value: String(cursor.nextIndex)),
                           URLQueryItem(name: "Limit", value: String(EmbyCursor.pageSize))],
            token: context.credential.token, user: context.credential.user))
        try current(context)
        guard let rows = response.Items else { throw EmbyFailure.response }
        var next = cursor
        try next.accept(count: rows.count, reportedTotal: response.TotalRecordCount,
                        fingerprint: EmbyCursor.fingerprint(rows, playlist: playlist))
        return ItemBatch(items: rows, cursor: next)
    }
    private func context() throws -> Context {
        guard let auth, isSignedIn else { throw EmbyFailure.signedOut }
        try current(auth); return auth
    }
    private func check(_ ticket: UUID, _ http: EmbyClient) throws {
        try Task.checkCancellation()
        guard generation == ticket, client === http else { throw CancellationError() }
    }
    private func current(_ context: Context) throws {
        try check(context.generation, context.client)
        guard auth === context else { throw CancellationError() }
    }
    private func safe(_ error: Error) -> EmbyFailure { error as? EmbyFailure ?? .network }
    private func failure(_ error: Error, _ context: Context) -> Error {
        guard generation == context.generation, auth === context, !Task.isCancelled,
              !(error is CancellationError) else { return CancellationError() }
        let result = safe(error)
        if case .unauthorized = result { _ = clearLocal() }
        errorMessage = result.localizedDescription
        return result
    }
    @discardableResult private func clearLocal() -> Bool {
        let scope = auth?.credential.scope ?? restoring?.scope
        generation = UUID(); artworkCache.clear(); client?.cancel(); client = nil; auth = nil; restoring = nil
        isSignedIn = false; accountName = ""; scopeID = nil
        songs = []; albums = []; playlists = []; isLoading = false; errorMessage = nil
        libraryPages = [:]; searchNotice = nil; playbackDiagnostic = nil; refreshID = UUID(); searchID = UUID()
        var clean = true
        do { try SecureVault.remove(key: Self.vaultKey) } catch { clean = false }
        if let scope, FileManager.default.fileExists(atPath: snapshotURL(scope).path) {
            do { try FileManager.default.removeItem(at: snapshotURL(scope)) } catch { clean = false }
        }
        if !clean { errorMessage = EmbyFailure.storage.localizedDescription }
        return clean
    }
    private func snapshotURL(_ scope: String) -> URL { cache.appendingPathComponent(scope + ".json") }
}
