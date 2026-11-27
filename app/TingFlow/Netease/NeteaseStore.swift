import Foundation
import Combine

@MainActor final class NeteaseStore: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var likedSongIDs: Set<String> = []
    @Published private(set) var hasLoadedLikes = false
    @Published private(set) var isLoadingLikes = false
    @Published private(set) var cloudPending: Set<String> = []
    @Published private(set) var cloudNeedsReview: Set<String> = []
    @Published private(set) var cloudMessage: String?
    @Published private(set) var accountName = "未登录"
    @Published private(set) var avatarURL: URL?
    @Published private(set) var scopeID: String? {
        didSet { if oldValue != scopeID { cancelCommentRequests() } }
    }
    // Comments never restore/save credentials or reuse a not-yet-verified login candidate.
    private var commentRequests: [UUID: Task<SongCommentPage, Error>] = [:]
    private let makeAnonymousCommentClient: @MainActor () -> NeteaseClient
    @Published private(set) var playlists: [NeteasePlaylist] = []
    @Published private(set) var dailySongs: [Song] = []
    @Published private(set) var dailyPlaylists: [NeteaseFeaturedPlaylist] = []
    @Published private(set) var personalizedPlaylists: [NeteaseFeaturedPlaylist] = []
    @Published private(set) var recommendationError: String?
    @Published private(set) var fmSongs: [Song] = []
    @Published private(set) var fmError: String?
    @Published private(set) var isLoadingFM = false
    private var fmID = UUID()
    @Published private(set) var isLoadingRecommendations = false
    var createdPlaylists: [NeteasePlaylist] { playlists.filter { $0.ownerID == userID } }
    var subscribedPlaylists: [NeteasePlaylist] { playlists.filter { $0.ownerID != userID } }
    private var recommendationID = UUID()
    private let makeClient: @MainActor () -> NeteaseClient
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackDiagnostic: String?
    @Published private(set) var cloudRecentSongs: [NeteaseRecentSong] = []
    @Published private(set) var isLoadingRecentSongs = false
    @Published private(set) var recentSongsMessage: String?
    @Published private(set) var syncPlaybackHistory = false
    @Published private(set) var historyUploadMessage: String?
    private var historyPaused = false
    private var historyConsentID = UUID()
    private var historyReadID = UUID()
    private var historyTasks: [String: Task<Void, Never>] = [:]
    private var historyTail: Task<Void, Never>?
    private var historyAttempts: Set<String> = []
    private var historyAcceptedStarts: Set<UUID> = []
    @Published private(set) var qrURL: URL?
    @Published private(set) var qrStatus = ""
    @Published private(set) var isAuthorizing = false

    private static let vaultKey = "netease.native.weapi.session.v1"
    // Replacing an authenticated client invalidates speculative playback even if scope is unchanged.
    @Published private(set) var playbackContextID = UUID()
    private var client: NeteaseClient? {
        didSet { if oldValue !== client { playbackContextID = UUID() } }
    }
    private var qrClient: NeteaseClient?
    private var qrTask: Task<Void, Never>?
    private var qrExpiryTask: Task<Void, Never>?
    private var userID: String?
    var currentUserID: String? { isSignedIn ? userID : nil }
    private var restorationDisabled = false
    private var generation = UUID()
    private var playbackTicket = UUID()
    private var qrGeneration = UUID()
    private var qrPollingID = UUID()
    private var qrWindow: NeteaseQRWindow?
    private var qrKey: String?
    var canResumeQRCode: Bool { qrClient != nil && qrWindow?.isExpired() == false }
    private var trackCache: [String: [Song]] = [:]
    init(clientFactory: (@MainActor () -> NeteaseClient)? = nil,
         anonymousCommentClientFactory: (@MainActor () -> NeteaseClient)? = nil) {
        makeClient = clientFactory ?? { NeteaseClient() }
        makeAnonymousCommentClient = anonymousCommentClientFactory ?? {
            // An ephemeral device identity avoids even a UserDefaults write for anonymous reading.
            let device = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
            return NeteaseClient(deviceID: String(device.prefix(52)))
        }
    }

    func refresh() async {
        #if DEBUG
        if UIPolishFixture.enabled { return }
        #endif
        guard !isLoading, !isAuthorizing, !restorationDisabled || client != nil else { return }
        let generation = self.generation
        isLoading = true
        errorMessage = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            if client == nil {
                guard !restorationDisabled else { return }
                let data: Data?
                do { data = try SecureVault.read(key: Self.vaultKey) } catch { throw NeteaseError.storage }
                guard let data else { return }
                let candidate = makeClient()
                try candidate.restoreCredential(data)
                client = candidate
            }
            guard let client else { return }
            let identity = try NeteaseMapping.identity(try await client.request(.identity))
            try ensureCurrent(generation)
            if let expected = userID ?? client.restoredUserID, expected != identity.id { throw NeteaseError.identity }
            try save(client, userID: identity.id)
            if userID != identity.id {
                clearCloudState(); clearHistoryState(); restoreHistoryChoice(uid: identity.id)
            }
            userID = identity.id
            scopeID = "netease:\(identity.id)"
            accountName = identity.name
            avatarURL = identity.avatar
            isSignedIn = true
            trackCache.removeAll()
            do {
                let loaded = try await loadPlaylists(client: client, uid: identity.id, generation: generation)
                try ensureCurrent(generation)
                try save(client, userID: identity.id)
                playlists = loaded
            } catch is CancellationError { return }
            catch {
                try ensureCurrent(generation)
                if error as? NeteaseError == .signedOut { throw NeteaseError.signedOut }
                errorMessage = "我的歌单：" + NeteaseError.message(error)
            }
            await loadRecommendations(client: client, scope: "netease:\(identity.id)", generation: generation)
        } catch is CancellationError {
        } catch {
            guard self.generation == generation else { return }
            if let reason = error as? NeteaseError, reason == .signedOut || reason == .identity {
                await signOut()
                if errorMessage != nil { return }
            }
            errorMessage = NeteaseError.message(error)
        }
    }

    /// Kumone's documented EAPI-backed daily endpoints; a failure never becomes demo content.
    private func loadRecommendations(client: NeteaseClient, scope: String, generation: UUID) async {
        let ticket = UUID(); recommendationID = ticket; isLoadingRecommendations = true
        defer { if recommendationID == ticket { isLoadingRecommendations = false } }
        var failures: [String] = []
        do {
            let body = try await client.request(.dailySongs)
            try ensureCurrent(generation)
            guard recommendationID == ticket else { return }
            dailySongs = try NeteaseMapping.dailySongs(body, scope: scope)
        } catch is CancellationError { return }
        catch {
            guard self.generation == generation, recommendationID == ticket else { return }
            if error as? NeteaseError == .signedOut { await signOut(); errorMessage = NeteaseError.signedOut.localizedDescription; return }
            failures.append("每日歌曲：" + NeteaseError.message(error))
        }
        do {
            let body = try await client.request(.dailyPlaylists)
            try ensureCurrent(generation)
            guard recommendationID == ticket else { return }
            dailyPlaylists = try NeteaseMapping.featuredPlaylists(body)
        } catch is CancellationError { return }
        catch {
            guard self.generation == generation, recommendationID == ticket else { return }
            if error as? NeteaseError == .signedOut { await signOut(); errorMessage = NeteaseError.signedOut.localizedDescription; return }
            failures.append("每日歌单：" + NeteaseError.message(error))
        }
        do {
            let body = try await client.request(.personalizedPlaylists, ["limit": 30, "total": true, "n": 1000])
            try ensureCurrent(generation)
            guard recommendationID == ticket else { return }
            personalizedPlaylists = try NeteaseMapping.personalizedPlaylists(body)
        } catch is CancellationError { return }
        catch {
            guard self.generation == generation, recommendationID == ticket else { return }
            failures.append("精选歌单：" + NeteaseError.message(error))
        }
        guard self.generation == generation, recommendationID == ticket else { return }
        recommendationError = failures.isEmpty ? nil : failures.joined(separator: "；")
    }
    func refreshRecommendations() async {
        guard isSignedIn, !isLoading, !isLoadingRecommendations, let client, let scope = scopeID else { return }
        await loadRecommendations(client: client, scope: scope, generation: generation)
    }

    /// Read-only FM batch, requested by the user's button; no trash/like writes.
    func loadPersonalFM() async {
        guard isSignedIn, !isLoadingFM, let client, let scope = scopeID else { return }
        let ticket = UUID(), account = generation; fmID = ticket; isLoadingFM = true; fmError = nil
        defer { if fmID == ticket { isLoadingFM = false } }
        do {
            let body = try await client.request(.personalFM)
            try ensureCurrent(account)
            guard fmID == ticket, let rows = body["data"] as? [[String: Any]] else { throw NeteaseError.response }
            fmSongs = rows.compactMap { NeteaseMapping.song($0, scope: scope) }
        } catch is CancellationError { }
        catch { if generation == account && fmID == ticket { fmError = NeteaseError.message(error) } }
    }

    /// Called ONLY by the explicit QR button; init/refresh never initiate authentication.
    func beginQRCodeLogin() {
        guard !isSignedIn, !isLoading else { return }
        cancelQRCodeLogin()
        let token = UUID()
        qrGeneration = token
        qrWindow = NeteaseQRWindow()
        let candidate = makeClient()
        qrClient = candidate
        isAuthorizing = true
        qrStatus = "正在创建二维码…"
        errorMessage = nil
        qrExpiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            guard let self, self.qrGeneration == token else { return }
            self.cancelQRCodeLogin()
            self.qrStatus = "二维码已过期，请重新生成。"
        }
        startQRCodePolling()
    }

    private func startQRCodePolling() {
        guard let candidate = qrClient, let window = qrWindow, !window.isPaused, !window.isExpired(), !isSignedIn else { return }
        qrTask?.cancel()
        let token = qrGeneration, accountGeneration = generation, pollID = UUID()
        qrPollingID = pollID
        let deadline = window.expiresAt
        qrTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.qrGeneration == token && self.qrPollingID == pollID { self.qrTask = nil }
            }
            do {
                let key: String
                if let saved = self.qrKey { key = saved }
                else {
                    let result = try await candidate.request(.qrKey, ["type": 3])
                    try self.ensureQR(token, accountGeneration, pollID)
                    guard let value = result["unikey"] as? String, !value.isEmpty, value.utf8.count < 512 else { throw NeteaseError.response }
                    key = value; self.qrKey = value
                }
                var components = URLComponents(string: "https://music.163.com/login")!
                components.queryItems = [URLQueryItem(name: "codekey", value: key)]
                self.qrURL = components.url
                self.qrStatus = "保存二维码到相册，在网易云 App 扫码确认后返回。"
                while true {
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    try self.ensureQR(token, accountGeneration, pollID)
                    guard Date() < deadline, self.qrWindow?.beginCheck() == true else { break }
                    let check = try await candidate.request(.qrCheck, ["key": key, "type": 3])
                    try self.ensureQR(token, accountGeneration, pollID)
                    guard Date() < deadline else { break }
                    switch check["code"] as? Int {
                    case 800:
                        self.cancelQRCodeLogin()
                        self.qrStatus = "二维码已过期，请重新生成。"
                        return
                    case 801: self.qrStatus = "等待扫码…"
                    case 802: self.qrStatus = "已扫码，请在网易云音乐 App 确认。"
                    case 803:
                        self.qrStatus = "正在核实账号身份…"
                        let identity = try NeteaseMapping.identity(try await candidate.request(.identity))
                        try self.ensureQR(token, accountGeneration, pollID)
                        guard Date() < deadline else { break }
                        try self.save(candidate, userID: identity.id)
                        self.client?.invalidate()
                        self.client = candidate
                        self.qrClient = nil // Ownership transferred only after canonical identity + Keychain success.
                        self.clearHistoryState(); self.restoreHistoryChoice(uid: identity.id)
                        self.userID = identity.id
                        self.restorationDisabled = false
                        self.scopeID = "netease:\(identity.id)"
                        self.accountName = identity.name
                        self.avatarURL = identity.avatar
                        self.isSignedIn = true
                        self.qrURL = nil
                        self.isAuthorizing = false
                        self.qrStatus = "已登录"
                        self.trackCache.removeAll()
                        self.qrGeneration = UUID()
                        self.qrExpiryTask?.cancel()
                        self.qrExpiryTask = nil
                        self.qrTask = nil
                        self.qrKey = nil; self.qrWindow = nil; self.qrPollingID = UUID()
                        await self.refresh()
                        return
                    default: throw NeteaseError.response
                    }
                }
                self.cancelQRCodeLogin()
                self.qrStatus = "二维码已过期，请重新生成。"
            } catch is CancellationError {
            } catch {
                guard self.qrGeneration == token, self.qrPollingID == pollID else { return }
                self.errorMessage = NeteaseError.message(error)
                self.qrStatus = "请求未完成，可在有效期内点击继续核验。"
            }
        }
    }

    func pauseQRCodeLogin() {
        guard qrClient != nil, qrWindow != nil else { return }
        qrWindow?.pause(); qrPollingID = UUID()
        qrTask?.cancel(); qrTask = nil
        qrStatus = "二维码已保留；返回听流后继续核验，有效期不会延长。"
    }
    func resumeQRCodeLogin() {
        guard qrClient != nil, let window = qrWindow else { return }
        if window.isExpired() { cancelQRCodeLogin(); qrStatus = "二维码已过期，请重新生成。"; return }
        if !window.isPaused, qrTask != nil { return }
        qrWindow?.resume(); errorMessage = nil
        startQRCodePolling()
    }

    func cancelQRCodeLogin() {
        qrGeneration = UUID()
        qrPollingID = UUID(); qrWindow = nil; qrKey = nil
        qrTask?.cancel()
        qrTask = nil
        qrExpiryTask?.cancel()
        qrExpiryTask = nil
        qrClient?.invalidate()
        qrClient = nil
        qrURL = nil
        isAuthorizing = false
        qrStatus = ""
    }
    func signOut() async {
        cancelCommentRequests()
        clearCloudState()
        restorationDisabled = true
        generation = UUID()
        cancelQRCodeLogin()
        client?.invalidate()
        client = nil
        userID = nil
        scopeID = nil
        accountName = "未登录"
        avatarURL = nil
        isSignedIn = false
        isLoading = false
        playlists.removeAll()
        dailySongs.removeAll(); dailyPlaylists.removeAll(); personalizedPlaylists.removeAll(); recommendationError = nil
        recommendationID = UUID(); isLoadingRecommendations = false
        fmID = UUID(); fmSongs = []; fmError = nil; isLoadingFM = false
        playbackDiagnostic = nil
        clearHistoryState()
        trackCache.removeAll()
        errorMessage = nil
        do { try SecureVault.remove(key: Self.vaultKey) }
        catch { errorMessage = NeteaseError.storage.errorDescription }
    }
    private func ensureCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func ensureQR(_ token: UUID, _ account: UUID, _ polling: UUID) throws {
        try ensureCurrent(account)
        guard qrGeneration == token, qrPollingID == polling, let window = qrWindow, !window.isPaused else { throw CancellationError() }
        guard Date() < window.expiresAt else {
            cancelQRCodeLogin(); qrStatus = "二维码已过期，请重新生成。"
            throw CancellationError()
        }
    }
    private func save(_ client: NeteaseClient, userID: String) throws {
        let data = try client.credentialData(userID: userID)
        do { try SecureVault.save(data, key: Self.vaultKey) } catch { throw NeteaseError.storage }
    }

    private func loadPlaylists(client: NeteaseClient, uid: String, generation: UUID) async throws -> [NeteasePlaylist] {
        var result: [NeteasePlaylist] = []
        var offset = 0
        let scope = "netease:\(uid)"
        for _ in 0..<100 {
            let body = try await client.request(.playlists, ["uid": uid, "limit": 100, "offset": offset, "includeVideo": true])
            try ensureCurrent(generation)
            guard let page = body["playlist"] as? [[String: Any]] else { throw NeteaseError.response }
            for row in page {
                guard let mapped = NeteaseMapping.playlist(row, scope: scope) else { throw NeteaseError.response }
                result.append(mapped)
            }
            offset += page.count
            guard let more = body["more"] as? Bool else { throw NeteaseError.response }
            if !more { return result }
            if page.isEmpty { throw NeteaseError.incomplete }
        }
        throw NeteaseError.incomplete
    }

    func tracks(in playlist: NeteasePlaylist) async throws -> [Song] {
        #if DEBUG
        if UIPolishFixture.enabled {
            guard playlist.accountScope == scopeID else { throw NeteaseError.signedOut }
            return trackCache[playlist.id] ?? []
        }
        #endif
        let token = generation
        guard isSignedIn, let client, let scope = scopeID, playlist.accountScope == scope else { throw NeteaseError.signedOut }
        if let cached = trackCache[playlist.id] { return cached }
        let body = try await client.request(.playlist, ["id": playlist.id, "n": min(1000, max(100, playlist.trackCount)), "s": 0])
        try ensureCurrent(token)
        guard let detail = body["playlist"] as? [String: Any],
              NeteaseMapping.id(detail["id"]) == playlist.id,
              let trackIDs = detail["trackIds"] as? [[String: Any]],
              let expectedCount = detail["trackCount"] as? Int else { throw NeteaseError.response }
        let ids = trackIDs.compactMap { NeteaseMapping.id($0["id"]) }
        guard ids.count == trackIDs.count, ids.count == expectedCount, ids.count <= 100000 else { throw NeteaseError.incomplete }
        // Use canonical inline detail first; many ordinary lists (including 257 songs)
        // already contain every song. Fetch only missing IDs instead of refetching all.
        var details = (detail["tracks"] as? [[String: Any]] ?? []).filter {
            NeteaseMapping.id($0["id"]) != nil && ($0["name"] as? String)?.isEmpty == false
        }
        let known = Set(details.compactMap { NeteaseMapping.id($0["id"]) })
        var seen = Set<String>()
        let missing = ids.filter { !known.contains($0) && seen.insert($0).inserted }
        for offset in stride(from: 0, to: missing.count, by: 500) {
            try Task.checkCancellation()
            let batch = Array(missing[offset..<min(offset + 500, missing.count)])
            let c = "[" + batch.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
            let response = try await client.request(.songs, ["c": c])
            try ensureCurrent(token)
            guard let rows = response["songs"] as? [[String: Any]] else { throw NeteaseError.response }
            details.append(contentsOf: rows)
        }
        try ensureCurrent(token)
        let tracks = NeteaseMapping.orderedSongs(ids: ids, details: details, scope: scope)
        // Memory-only, one active account; never cache credentials or signed audio URLs with songs.
        if tracks.count <= 10000 {
            if trackCache.count >= 8 { trackCache.removeAll() }
            trackCache[playlist.id] = tracks
        }
        return tracks
    }

    private func context(for song: Song) throws -> (NeteaseClient, UUID) {
        guard song.platform == .netease, NeteaseMapping.id(song.platformID) == song.platformID,
              isSignedIn, let client, let scopeID,
              song.accountScope == nil || song.accountScope == scopeID else { throw NeteaseError.signedOut }
        return (client, generation)
    }
    func playback(for song: Song, quality: AudioQuality = .high, mode: NeteasePlaybackMode = .nativeV1) async throws -> PlaybackResource {
        let ticket = UUID(); playbackTicket = ticket
        playbackDiagnostic = nil
        let (client, token) = try context(for: song)
        defer {
            if generation == token && playbackTicket == ticket && !Task.isCancelled {
                playbackDiagnostic = client.playbackDiagnostic?.text
            }
        }
        do {
            let body: [String: Any]
            switch mode {
            case .nativeV1:
                let payload = try NeteaseAudioPolicy.payload(songID: song.platformID, quality: quality)
                body = try await client.request(.playbackV1, payload)
            case .legacyStandard:
                // Explicit choice before requesting; never an automatic reaction to a denial.
                body = try await client.request(.playback, NeteaseAudioPolicy.legacyPayload(songID: song.platformID))
            }
            try ensureCurrent(token)
            var resource = try NeteaseMapping.playback(body, songID: song.platformID)
            resource.neteaseHistoryScope = scopeID
            return resource
        } catch NeteaseError.verification {
            try ensureCurrent(token)
            // Request-specific numeric refusals already travel as playbackVerification.
            // Never infer this request's error from another playback's shared diagnostic.
            throw NeteaseError.verification
        }
    }
    /// Includes auth epoch, not just UID: signing back into the same account cannot revive old pages.
    var commentContextID: String { generation.uuidString + ":" + (isSignedIn ? (scopeID ?? "unverified") : "anonymous") }
    private func cancelCommentRequests() {
        for task in commentRequests.values { task.cancel() }
        commentRequests.removeAll()
    }
    func comments(for song: Song, sort: CommentSort, page: Int, cursor: String?) async throws -> SongCommentPage {
        try Task.checkCancellation()
        guard song.platform == .netease, SongCommentMapping.validID(song.platformID) else { throw NeteaseError.unavailable }
        guard song.accountScope == nil || (isSignedIn && song.accountScope == scopeID) else { throw NeteaseError.signedOut }
        let payload = try SongCommentMapping.payload(songID: song.platformID, sort: sort, page: page, cursor: cursor)
        let context = commentContextID, ticket = UUID()
        let authenticated = isSignedIn ? client : nil
        let anonymous = authenticated == nil
        let reader = authenticated ?? makeAnonymousCommentClient()
        let worker = Task { @MainActor in
            let body = try await reader.request(.comments, payload)
            try Task.checkCancellation()
            return try SongCommentMapping.decode(body)
        }
        commentRequests[ticket] = worker
        let started = Date()
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            worker.cancel()
        }
        defer {
            deadline.cancel(); commentRequests.removeValue(forKey: ticket)
            if anonymous { reader.invalidate() }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard context == commentContextID else { throw CancellationError() }
            guard Date().timeIntervalSince(started) < 25 else { throw SongCommentError.timedOut }
            return result
        } catch {
            if Task.isCancelled || context != commentContextID { throw CancellationError() }
            if Date().timeIntervalSince(started) >= 25 { throw SongCommentError.timedOut }
            throw error
        }
    }
    func lyrics(for song: Song) async throws -> String {
        let (client, token) = try context(for: song)
        let body = try await client.request(.lyric, ["id": song.platformID, "tv": -1, "lv": -1, "rv": -1, "kv": -1, "_nmclfl": 1])
        try ensureCurrent(token)
        return (body["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
    }
}

// Cloud writes are reachable only from the three explicit mutation methods below.
@MainActor extension NeteaseStore {
    private typealias CloudContext = (client: NeteaseClient, epoch: UUID, uid: String, scope: String)

    private func clearCloudState() {
        likedSongIDs = []; hasLoadedLikes = false; isLoadingLikes = false
        cloudPending = []; cloudNeedsReview = []; cloudMessage = nil
    }
    private func cloudContext() throws -> CloudContext {
        guard isSignedIn, let client, let uid = userID, NeteaseMapping.id(uid) == uid,
              let scope = scopeID, scope == "netease:\(uid)" else { throw NeteaseCloudFailure.invalidAccount }
        // Also validate that the verified session still has a usable credential; never expose it.
        _ = try client.credentialData(userID: uid)
        return (client, generation, uid, scope)
    }
    private func cloudSongID(_ song: Song, in account: CloudContext) throws -> String {
        guard song.platform == .netease, song.accountScope == nil || song.accountScope == account.scope else {
            throw NeteaseCloudFailure.invalidInput
        }
        return try NeteaseCloudPolicy.identifier(song.platformID)
    }
    private func cloudPlaylistID(_ list: NeteasePlaylist, in account: CloudContext) throws -> String {
        guard list.accountScope == account.scope else { throw NeteaseCloudFailure.invalidInput }
        return try NeteaseCloudPolicy.identifier(list.id)
    }
    private func isCloudCurrent(_ account: CloudContext) -> Bool {
        generation == account.epoch && client === account.client && isSignedIn &&
            userID == account.uid && scopeID == account.scope
    }
    private func ensureCloudCurrent(_ account: CloudContext) throws {
        try ensureCurrent(account.epoch)
        guard isCloudCurrent(account) else { throw CancellationError() }
    }
    private func beginCloudWrite(_ key: String) throws {
        guard !cloudNeedsReview.contains(key) else { throw NeteaseCloudFailure.needsRefresh }
        guard cloudPending.isEmpty, !isLoadingLikes, !isLoading else { throw NeteaseCloudFailure.busy }
        cloudPending.insert(key); cloudMessage = nil
    }
    private func cloudFailure(_ error: Error, in account: CloudContext, key: String,
                              submitted: Bool, accepted: Bool) async -> Error {
        guard isCloudCurrent(account) else { return CancellationError() }
        if error as? NeteaseError == .signedOut || error as? NeteaseError == .identity {
            await signOut()
            return NeteaseError.signedOut
        }
        if submitted && (accepted || NeteaseCloudPolicy.mayHaveApplied(error)) {
            cloudNeedsReview.insert(key)
            cloudMessage = NeteaseCloudFailure.unconfirmed.localizedDescription
            return NeteaseCloudFailure.unconfirmed
        }
        cloudMessage = NeteaseCloudPolicy.safeMessage(error)
        if error is CancellationError || error is NeteaseError || error is NeteaseCloudFailure { return error }
        return NeteaseCloudFailure.unknownResult
    }
    func isCloudLiked(_ song: Song) -> Bool {
        guard isSignedIn, hasLoadedLikes, song.platform == .netease,
              let scopeID, song.accountScope == nil || song.accountScope == scopeID,
              NeteaseMapping.id(song.platformID) == song.platformID else { return false }
        return likedSongIDs.contains(song.platformID)
    }
    private func readCloudLikes(_ account: CloudContext) async throws -> Set<String> {
        let body = try await account.client.request(.likedTracks, NeteaseCloudPolicy.likesPayload(uid: account.uid))
        try ensureCloudCurrent(account)
        return try NeteaseCloudPolicy.likedIDs(body)
    }
}

#if DEBUG
@MainActor extension NeteaseStore {
    func seedPolishFixture() {
        guard UIPolishFixture.enabled else { return }
        userID = "700001"; scopeID = UIPolishFixture.scope; accountName = "听流测试账号"; avatarURL = UIPolishFixture.url("a")
        playlists = UIPolishFixture.playlists; dailySongs = UIPolishFixture.songs; fmSongs = Array(dailySongs.prefix(3))
        dailyPlaylists = playlists.prefix(3).map { NeteaseFeaturedPlaylist(id: $0.id, name: $0.name, description: "原生界面测试数据", coverURL: $0.coverURL, playCount: 0, trackCount: 6) }
        personalizedPlaylists = dailyPlaylists; isSignedIn = true
        for list in playlists { trackCache[list.id] = dailySongs }
    }
}
#endif

@MainActor extension NeteaseStore {
    /// Read-only reconciliation. A failed read preserves the last confirmed snapshot and locks.
    func refreshCloudLikes() async {
        guard cloudPending.isEmpty, !isLoadingLikes else { cloudMessage = NeteaseCloudFailure.busy.localizedDescription; return }
        let account: CloudContext
        do { account = try cloudContext() }
        catch { cloudMessage = NeteaseCloudPolicy.safeMessage(error); return }
        isLoadingLikes = true; cloudMessage = nil
        defer { if isCloudCurrent(account) { isLoadingLikes = false } }
        do {
            let actual = try await readCloudLikes(account)
            try ensureCloudCurrent(account)
            likedSongIDs = actual; hasLoadedLikes = true
            cloudNeedsReview = cloudNeedsReview.filter { !$0.hasPrefix("like:") }
        } catch {
            guard isCloudCurrent(account) else { return }
            if error as? NeteaseError == .signedOut { await signOut(); return }
            cloudMessage = NeteaseCloudPolicy.safeMessage(error)
        }
    }

    /// Explicit desired state, one write at most. Both no-op and success require fresh proof.
    func setCloudLiked(_ song: Song, liked: Bool) async throws {
        let account = try cloudContext(), id = try cloudSongID(song, in: account)
        let key = "like:" + id
        try beginCloudWrite(key)
        defer { if generation == account.epoch { cloudPending.remove(key) } }
        var submitted = false, accepted = false
        do {
            let before = try await readCloudLikes(account)
            try ensureCloudCurrent(account)
            if before.contains(id) == liked {
                likedSongIDs = before; hasLoadedLikes = true; return
            }
            try Task.checkCancellation()
            submitted = true
            _ = try await account.client.request(.likeTrack, NeteaseCloudPolicy.likePayload(id: id, liked: liked))
            accepted = true
            try ensureCloudCurrent(account)
            let actual = try await readCloudLikes(account)
            try ensureCloudCurrent(account)
            guard actual.contains(id) == liked else { throw NeteaseCloudFailure.unconfirmed }
            likedSongIDs = actual; hasLoadedLikes = true
        } catch {
            throw await cloudFailure(error, in: account, key: key, submitted: submitted, accepted: accepted)
        }
    }

    /// Explicit read reconciliation only. Track locks clear only after fresh, complete detail reads.
    func refreshCloudPlaylists() async {
        let account: CloudContext
        do { account = try cloudContext() }
        catch { cloudMessage = NeteaseCloudPolicy.safeMessage(error); return }
        let key = "refresh:playlists"
        guard cloudPending.isEmpty, !isLoading, !isLoadingLikes else { cloudMessage = NeteaseCloudFailure.busy.localizedDescription; return }
        cloudPending.insert(key); cloudMessage = nil
        defer { if generation == account.epoch { cloudPending.remove(key) } }
        do {
            let actual = try await loadPlaylists(client: account.client, uid: account.uid, generation: account.epoch)
            try ensureCloudCurrent(account)
            var reconciled = Set(cloudNeedsReview.filter { $0.hasPrefix("playlist:") })
            for lock in cloudNeedsReview.filter({ $0.hasPrefix("tracks:") }).sorted() {
                let id = String(lock.dropFirst("tracks:".count))
                let body = try await account.client.request(.playlist, NeteaseCloudPolicy.detailPayload(id: id))
                try ensureCloudCurrent(account)
                _ = try NeteaseCloudPolicy.detail(body, id: id)
                trackCache.removeValue(forKey: id)
                reconciled.insert(lock)
            }
            try ensureCloudCurrent(account)
            playlists = actual; cloudNeedsReview.subtract(reconciled)
            trackCache.removeAll()
        } catch {
            guard isCloudCurrent(account) else { return }
            if error as? NeteaseError == .signedOut { await signOut(); return }
            cloudMessage = NeteaseCloudPolicy.safeMessage(error)
        }
    }
}

@MainActor extension NeteaseStore {
    func setCloudPlaylistSubscribed(_ list: NeteasePlaylist, subscribed: Bool) async throws {
        let account = try cloudContext(), id = try cloudPlaylistID(list, in: account)
        let key = "playlist:" + id
        try beginCloudWrite(key)
        defer { if generation == account.epoch { cloudPending.remove(key) } }
        var submitted = false, accepted = false
        do {
            // A stale view's ownerID is not authorization, even for subscribe/unsubscribe.
            let detail = try await account.client.request(.playlist, NeteaseCloudPolicy.detailPayload(id: id))
            try ensureCloudCurrent(account)
            guard try NeteaseCloudPolicy.detail(detail, id: id).ownerID != account.uid else { throw NeteaseCloudFailure.notOwner }
            let before = try await loadPlaylists(client: account.client, uid: account.uid, generation: account.epoch)
            try ensureCloudCurrent(account)
            guard !before.contains(where: { $0.id == id && $0.ownerID == account.uid }) else { throw NeteaseCloudFailure.notOwner }
            if before.contains(where: { $0.id == id }) == subscribed {
                playlists = before; trackCache.removeValue(forKey: id); return
            }
            try Task.checkCancellation()
            submitted = true
            _ = try await account.client.request(NeteaseCloudPolicy.subscription(subscribed), NeteaseCloudPolicy.playlistPayload(id: id))
            accepted = true
            try ensureCloudCurrent(account)
            let actual = try await loadPlaylists(client: account.client, uid: account.uid, generation: account.epoch)
            try ensureCloudCurrent(account)
            guard actual.contains(where: { $0.id == id }) == subscribed else { throw NeteaseCloudFailure.unconfirmed }
            if let row = actual.first(where: { $0.id == id }), row.ownerID == account.uid { throw NeteaseCloudFailure.unconfirmed }
            playlists = actual; trackCache.removeValue(forKey: id)
        } catch {
            throw await cloudFailure(error, in: account, key: key, submitted: submitted, accepted: accepted)
        }
    }

    func addCloudSong(_ song: Song, to list: NeteasePlaylist) async throws {
        let account = try cloudContext(), songID = try cloudSongID(song, in: account)
        let id = try cloudPlaylistID(list, in: account), key = "tracks:" + id
        try beginCloudWrite(key)
        defer { if generation == account.epoch { cloudPending.remove(key) } }
        var submitted = false, accepted = false
        do {
            let beforeBody = try await account.client.request(.playlist, NeteaseCloudPolicy.detailPayload(id: id))
            try ensureCloudCurrent(account)
            let before = try NeteaseCloudPolicy.detail(beforeBody, id: id)
            guard before.ownerID == account.uid else { throw NeteaseCloudFailure.notOwner }
            if before.trackIDs.contains(songID) { trackCache.removeValue(forKey: id); return }
            try Task.checkCancellation()
            submitted = true
            _ = try await account.client.request(.manipulatePlaylistTracks, NeteaseCloudPolicy.addPayload(songID: songID, playlistID: id))
            accepted = true
            try ensureCloudCurrent(account)
            let actualBody = try await account.client.request(.playlist, NeteaseCloudPolicy.detailPayload(id: id))
            try ensureCloudCurrent(account)
            let actual = try NeteaseCloudPolicy.detail(actualBody, id: id)
            guard actual.ownerID == account.uid, actual.trackIDs.contains(songID) else { throw NeteaseCloudFailure.unconfirmed }
            trackCache.removeValue(forKey: id)
            // Detail is fresh proof; update only this existing row, never refresh recommendations.
            if let row = actualBody["playlist"] as? [String: Any],
               let mapped = NeteaseMapping.playlist(row, scope: account.scope),
               let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index] = mapped }
        } catch {
            throw await cloudFailure(error, in: account, key: key, submitted: submitted, accepted: accepted)
        }
    }
}


// Playback-history reporting is independent of likes/playlists and defaults to OFF per account.
@MainActor extension NeteaseStore {
    private func historyChoiceKey(_ uid: String) -> String { "tingflow.netease.history.enabled." + uid }
    private func restoreHistoryChoice(uid: String) {
        syncPlaybackHistory = UserDefaults.standard.bool(forKey: historyChoiceKey(uid))
    }
    private func clearHistoryState() {
        historyConsentID = UUID(); historyReadID = UUID()
        for task in historyTasks.values { task.cancel() }
        historyTasks = [:]; historyTail = nil; historyAttempts = []; historyAcceptedStarts = []
        cloudRecentSongs = []; isLoadingRecentSongs = false; recentSongsMessage = nil
        syncPlaybackHistory = false; historyPaused = false; historyUploadMessage = nil
    }
    func setPlaybackHistorySync(_ enabled: Bool) {
        guard isSignedIn, let uid = userID else { return }
        historyConsentID = UUID()
        for task in historyTasks.values { task.cancel() }
        historyTasks = [:]; historyTail = nil
        syncPlaybackHistory = enabled; historyPaused = false
        UserDefaults.standard.set(enabled, forKey: historyChoiceKey(uid))
        historyUploadMessage = enabled ? "已开启：仅同步之后真实播放的网易云原平台完整音频，不补报旧记录。" : "已关闭上报；已经发出的请求不能撤回，不会继续重试。"
    }
    func refreshCloudRecentSongs() async {
        guard !isLoadingRecentSongs else { return }
        let account: CloudContext
        do { account = try cloudContext() }
        catch { recentSongsMessage = NeteaseCloudUIFree.message(error); return }
        let ticket = UUID(); historyReadID = ticket; isLoadingRecentSongs = true
        defer { if historyReadID == ticket { isLoadingRecentSongs = false } }
        do {
            let body = try await account.client.request(.recentSongs, ["limit": NeteaseHistoryPolicy.maximumRows])
            try ensureCloudCurrent(account)
            guard historyReadID == ticket else { return }
            cloudRecentSongs = try NeteaseHistoryPolicy.recentSongs(body, scope: account.scope)
            recentSongsMessage = "已从网易云读取 \(cloudRecentSongs.count) 首最近播放；这不是累计听歌次数或跨设备进度。"
        } catch is CancellationError { }
        catch { if isCloudCurrent(account), historyReadID == ticket { recentSongsMessage = NeteaseCloudUIFree.message(error) } }
    }
    func enqueueListeningStart(_ session: ListeningSession) {
        enqueueHistory(sessionID: session.id, song: session.song, scope: session.scope, seconds: nil, naturalEnd: false)
    }
    func enqueueListeningFinish(_ snapshot: ListeningSession.Snapshot, naturalEnd: Bool) {
        enqueueHistory(sessionID: snapshot.id, song: snapshot.song, scope: snapshot.scope,
            seconds: snapshot.listenedSeconds, naturalEnd: naturalEnd)
    }
    private func enqueueHistory(sessionID: UUID, song: Song, scope: String, seconds: Double?, naturalEnd: Bool) {
        guard syncPlaybackHistory, !historyPaused, song.platform == .netease else { return }
        let account: CloudContext
        do { account = try cloudContext() }
        catch { historyUploadMessage = NeteaseCloudUIFree.message(error); return }
        guard account.scope == scope, song.accountScope == nil || song.accountScope == scope else { return }
        let key = sessionID.uuidString + (seconds == nil ? ":start" : ":finish")
        guard !historyAttempts.contains(key) else { return }
        guard historyTasks.count < 16, historyAttempts.count < 2000 else {
            historyPaused = true; historyUploadMessage = "上报队列已达安全限制，已暂停；不会继续重复发送。"; return
        }
        historyAttempts.insert(key)
        let consent = historyConsentID, previous = historyTail
        let task = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer { self.historyTasks.removeValue(forKey: key) }
            do {
                try Task.checkCancellation()
                guard self.syncPlaybackHistory, !self.historyPaused, self.historyConsentID == consent else { return }
                try self.ensureCloudCurrent(account)
                // Finishing without an accepted start is not a verified listening-ranking session.
                if seconds != nil, !self.historyAcceptedStarts.contains(sessionID) { return }
                let payload = try NeteaseHistoryPolicy.logs(action: seconds == nil ? .startplay : .play,
                    songID: song.platformID, seconds: seconds ?? 0,
                    endReason: naturalEnd ? .naturalEnd : nil)
                _ = try await account.client.request(.playbackLog, payload)
                try self.ensureCloudCurrent(account)
                guard self.syncPlaybackHistory, self.historyConsentID == consent else { return }
                if seconds == nil { self.historyAcceptedStarts.insert(sessionID) }
                self.historyUploadMessage = seconds == nil ? "开始事件已受理；请刷新云端最近播放核对，官方端可能延迟显示。" : "实际听歌时间上报已受理；是否计入官方排行由平台决定。"
            } catch is CancellationError { }
            catch {
                guard self.isCloudCurrent(account), self.historyConsentID == consent else { return }
                self.historyPaused = true
                self.historyUploadMessage = "播放记录上报未确认，已暂停且不自动重试：" + NeteaseCloudUIFree.message(error)
            }
        }
        historyTasks[key] = task; historyTail = task
    }
}

/// UI-free error formatting for standalone protocol/Store tests.
private enum NeteaseCloudUIFree {
    static func message(_ error: Error) -> String {
        if let value = error as? NeteaseCloudFailure { return value.localizedDescription }
        if let value = error as? NeteaseError { return value.localizedDescription }
        return "读取或上报未完成；旧快照已保留，不会自动重复写入。"
    }
}
