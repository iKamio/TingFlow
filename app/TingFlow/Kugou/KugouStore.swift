import Foundation
import Combine

protocol KugouCredentialVault {
    func read() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}
struct KugouKeychainVault: KugouCredentialVault {
    static let key = "kugou.native.standard1005.credential.v1"
    func read() throws -> Data? { try SecureVault.read(key: Self.key) }
    func save(_ data: Data) throws { try SecureVault.save(data, key: Self.key) }
    func remove() throws { try SecureVault.remove(key: Self.key) }
}

@MainActor final class KugouStore: ObservableObject {
    @Published private(set) var profile: KugouProfile?
    @Published private(set) var playlists: [KugouPlaylist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var qrURL: URL?
    @Published private(set) var qrStatus = ""
    @Published private(set) var isAuthorizing = false
    @Published private(set) var credentialRemovalPending = false
    var isSignedIn: Bool { profile != nil && credential != nil }
    var accountScope: String? { isSignedIn ? credential.map { "kugou:\($0.userID)" } : nil }
    var scopeID: String? { accountScope }
    var accountName: String { profile?.name ?? "未登录" }
    var createdPlaylists: [KugouPlaylist] { playlists.filter { $0.kind == .created } }
    var collectedPlaylists: [KugouPlaylist] { playlists.filter { $0.kind == .collected } }
    var canResumeQRCode: Bool { qrKey != nil && qrWindow?.valid(now: now()) == true }

    private let client: any KugouServing
    private let vault: any KugouCredentialVault
    // The public epoch is random; it never exposes the credential or its hash.
    @Published private(set) var playbackContextID = UUID()
    private var credential: KugouCredential? {
        didSet { if oldValue != credential { playbackContextID = UUID() } }
    }
    private var generation = UUID()
    private var qrGeneration = UUID()
    private var pollGeneration = UUID()
    private var qrKey: String?
    private var qrDevice: KugouDevice?
    private var qrWindow: KugouQRWindow?
    private var pollTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var trackTasks: [UUID: Task<[Song], Error>] = [:]
    private var trackCache: [String: [Song]] = [:]
    private var foreground = true
    private var restored = false
    private var restoreBlocked = false
    private var refreshID = UUID()
    private let now: () -> Date
    private let sleep: (UInt64) async throws -> Void
    init(client: any KugouServing = KugouClient(), vault: any KugouCredentialVault = KugouKeychainVault(),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.client = client; self.vault = vault; self.now = now; self.sleep = sleep
    }
    deinit { restoreTask?.cancel(); pollTask?.cancel(); expiryTask?.cancel(); refreshTask?.cancel(); trackTasks.values.forEach { $0.cancel() } }

    /// Restores only this platform's Keychain item. ID-only profile is not live verification.
    func restore() async {
        guard !restored, !restoreBlocked, foreground else { return }
        restored = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }; await self.restoreAccount()
        }
        restoreTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    private func restoreAccount() async {
        let ticket = generation
        do {
            let data: Data?
            do { data = try vault.read() } catch { restored = false; throw KugouError.storage }
            guard let data else { return }
            guard data.count <= 4096, let candidate = try? JSONDecoder().decode(KugouCredential.self, from: data), candidate.isValid else { throw KugouError.storage }
            try ensure(ticket)
            credential = candidate; profile = idOnly(candidate)
            await refresh()
        } catch is CancellationError { if ticket == generation { restored = false } }
        catch { if ticket == generation { errorMessage = KugouError.message(error) } }
    }
    private func idOnly(_ c: KugouCredential) -> KugouProfile {
        KugouProfile(id: c.userID, name: "酷狗 ID：\(c.userID)", avatar: nil)
    }
    private func ensure(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard ticket == generation, foreground else { throw CancellationError() }
    }
    private func cancelReads() {
        restoreTask?.cancel(); restoreTask = nil
        refreshID = UUID(); refreshTask?.cancel(); refreshTask = nil
        trackTasks.values.forEach { $0.cancel() }; trackTasks.removeAll()
        isLoading = false
    }
    func refresh() async {
        guard foreground, !isLoading, let c = credential, profile?.id == c.userID else { return }
        let ticket = generation, operation = UUID()
        refreshID = operation; isLoading = true; errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket && self.refreshID == operation { self.isLoading = false; self.refreshTask = nil } }
            do {
                var window = KugouPageWindow(pageSize: 100)
                var all: [KugouPlaylist] = []; var ids = Set<String>()
                while true {
                    try self.ensure(ticket)
                    let result = try await self.client.playlists(c, page: window.page + 1, size: 100)
                    try self.ensure(ticket)
                    let more = try window.accept(result)
                    for list in result.items {
                        guard list.accountScope == "kugou:\(c.userID)", ids.insert(list.id).inserted else { throw KugouError.pagination }
                    }
                    all.append(contentsOf: result.items)
                    if !more { break }
                }
                self.playlists = all; self.trackCache.removeAll()
            } catch is CancellationError { }
            catch { if self.generation == ticket { self.errorMessage = KugouError.message(error) } }
        }
        refreshTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func tracks(in list: KugouPlaylist, forceReload: Bool = false) async throws -> [Song] {
        guard foreground, let c = credential, accountScope == list.accountScope,
              playlists.contains(where: { $0.id == list.id && $0.accountScope == list.accountScope }) else { throw KugouError.identity }
        if !forceReload, let cached = trackCache[list.id] { return cached }
        guard trackTasks.count < 2 else { throw KugouError.rateLimited }
        let ticket = generation, id = UUID()
        let task = Task { [weak self] () throws -> [Song] in
            guard let self else { throw CancellationError() }
            var window = KugouPageWindow(pageSize: 100)
            var all: [Song] = []
            while true {
                try self.ensure(ticket)
                let result = try await self.client.tracks(c, listID: list.id, page: window.page + 1, size: 100)
                try self.ensure(ticket)
                let more = try window.accept(result)
                guard result.items.allSatisfy({ $0.accountScope == list.accountScope && $0.platform == .kugou }) else { throw KugouError.identity }
                all.append(contentsOf: result.items)
                if !more { break }
            }
            // One bounded playlist cache, not an unbounded account-wide song archive.
            self.trackCache = [list.id: all]
            return all
        }
        trackTasks[id] = task
        defer { trackTasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    /// Must be called only by an explicit user button, never onAppear/task.
    func startQRCodeLogin() {
        guard foreground else { return }
        cancelQRCodeLogin()
        qrDevice = .fresh(); qrWindow = KugouQRWindow(now: now())
        isAuthorizing = true; qrStatus = "正在向酷狗申请二维码…"; errorMessage = nil
        let ticket = qrGeneration
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            do { try await sleep(120_000_000_000) } catch { return }
            guard let self, self.qrGeneration == ticket else { return }
            self.endQR(message: KugouError.expired.errorDescription!)
        }
        beginPolling()
    }
    private func beginPolling() {
        guard foreground, isAuthorizing, let device = qrDevice else { return }
        let ticket = qrGeneration, poll = UUID()
        pollGeneration = poll
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.qrKey == nil {
                    let key = try await self.client.qrKey(device: device)
                    try self.ensureQR(ticket, poll)
                    self.qrKey = key; self.qrURL = try KugouMapping.qrURL(key)
                    self.qrStatus = "请用酷狗音乐 App 扫码并确认（只读同步）"
                }
                guard let key = self.qrKey else { throw KugouError.response }
                while true {
                    try await self.sleep(2_500_000_000)
                    try self.ensureQR(ticket, poll)
                    guard self.qrWindow?.beginCheck(now: self.now()) == true else { throw KugouError.expired }
                    let result = try await self.client.checkQR(key, device: device)
                    try self.ensureQR(ticket, poll)
                    switch result {
                    case .expired: throw KugouError.expired
                    case .waiting: self.qrStatus = "等待酷狗 App 扫码…"
                    case .scanned: self.qrStatus = "已扫码，请在酷狗 App 确认登录…"
                    case .authorized(let candidate):
                        guard candidate.isValid, candidate.device == device else { throw KugouError.identity }
                        // The authorized official QR response supplies ID+token. No unverified profile endpoint.
                        // Preserve the previous account if local secure storage fails.
                        do { try self.vault.save(JSONEncoder().encode(candidate)) } catch { throw KugouError.storage }
                        self.generation = UUID(); self.cancelReads(); self.trackCache.removeAll(); self.playlists = []
                        self.credential = candidate; self.profile = self.idOnly(candidate); self.restored = true; self.restoreBlocked = false
                        self.credentialRemovalPending = false
                        self.endQR(message: "已登录酷狗，云端只读", cancelPoll: false)
                        await self.refresh()
                        return
                    }
                }
            } catch is CancellationError { }
            catch {
                guard self.qrGeneration == ticket, self.pollGeneration == poll else { return }
                self.endQR(message: KugouError.message(error))
            }
        }
    }
    private func ensureQR(_ ticket: UUID, _ poll: UUID) throws {
        try Task.checkCancellation()
        guard ticket == qrGeneration, poll == pollGeneration, foreground else { throw CancellationError() }
        guard qrWindow?.live(now: now()) == true else { throw KugouError.expired }
    }
    private func endQR(message: String, cancelPoll: Bool = true) {
        qrGeneration = UUID(); pollGeneration = UUID()
        if cancelPoll { pollTask?.cancel() }
        pollTask = nil; expiryTask?.cancel(); expiryTask = nil
        qrKey = nil; qrDevice = nil; qrWindow = nil; qrURL = nil; isAuthorizing = false; qrStatus = message
    }
    func cancelQRCodeLogin() { endQR(message: "") }
    /// Scene inactive/background stops requests. The wall-clock deadline is never extended.
    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if !active {
            generation = UUID()
            if credential == nil { restored = false }
            cancelReads(); pollGeneration = UUID(); pollTask?.cancel(); pollTask = nil
            if isAuthorizing && qrKey == nil {
                endQR(message: "二维码申请已取消，请返回后主动重新生成。")
            } else { qrWindow?.pause() }
        } else if isAuthorizing {
            guard qrWindow?.resume(now: now()) == true else { endQR(message: KugouError.expired.errorDescription!); return }
            beginPolling()
        }
    }
    /// Local sign-out only; there is intentionally no unverified remote logout/mutation endpoint.
    func signOut() {
        generation = UUID(); cancelQRCodeLogin(); cancelReads()
        credential = nil; profile = nil; playlists = []; trackCache.removeAll()
        restored = true; restoreBlocked = true; errorMessage = nil
        credentialRemovalPending = true
        do { try vault.remove(); credentialRemovalPending = false }
        catch { errorMessage = "本次已退出，但设备凭据未能删除。请解锁后点重试删除；重新启动前请重试。" }
    }
}
