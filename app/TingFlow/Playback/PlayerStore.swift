import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var current: Song?
    @Published private(set) var queue: [Song] = []
    @Published private(set) var index = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var qualityLabel = "原始音频"
    @Published private(set) var isPreview = false
    @Published private(set) var artworkImage: UIImage?
    @Published private(set) var sourceLabel = ""
    @Published var shuffle = false {
        didSet {
            if shuffle != oldValue { transitionResolutionContextDidChange(); rebuildOrder() }
        }
    }
    @Published var repeatMode: RepeatMode = .sequential {
        didSet { if repeatMode != oldValue { transitionResolutionContextDidChange() } }
    }
    var resolver: ((Song) async throws -> PlaybackResource)?
    var onStarted: ((Song) -> Void)?
    var onListeningStarted: ((ListeningSession) -> Void)?
    var onListeningFinished: ((ListeningSession.Snapshot, Bool) -> Void)?
    var reportsListening = false {
        didSet {
            if reportsListening != oldValue { listeningSession = nil; listeningCycleID = UUID() }
        }
    }
    private var listeningScope: String?
    private var listeningSession: ListeningSession?
    private var listeningCycleID = UUID()

    private let anchorPlayer = AVPlayer()
    /// While an incoming deck is promoted it becomes the active AVPlayer; otherwise playback stays on anchorPlayer.
    private var player: AVPlayer { activeDeck?.player ?? anchorPlayer }
    private var generation = UUID()
    private var resolving: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: (identity: NowPlayingArtworkIdentity, value: MPMediaItemArtwork)?
    private var loader: AuthenticatedAudioLoader?
    private var itemObservation: NSKeyValueObservation?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var clock: Any?
    private var commands: [(MPRemoteCommand, Any)] = []
    private var order: [Int] = []
    private var wantsPlay = false
    private var reportedStart = false
    private var ended = false
    private var interruptionResume: UUID?
    private var activeDeck: PlaybackTransitionDeck?
    private var pendingDeck: PlaybackTransitionDeck?
    private var pendingSong: Song?
    private var pendingTicket: PlaybackTransitionTicket?
    private var pendingPlan: BeatTransitionPlan?
    private var pendingIncomingOffset = 0.0
    private var pendingPrepared = false
    private var preparationDeadlineTask: Task<Void, Never>?
    private let anchorOnsetCapture = PlaybackOnsetCapture()
    private var activeOnsetCapture: PlaybackOnsetCapture { activeDeck?.onsetCapture ?? anchorOnsetCapture }
    private var transitionStarting = false
    private var transitionStartDeadline = 0.0
    private var transitionCancelledForCurrentItem = false
    private var fading = false
    private var fadeStart = 0.0
    private var fadeDuration = 0.0
    private var fadeTimer: Timer?
    private var preloadingTask: Task<Void, Never>?
    private var resolvingTicket: PlaybackTransitionTicket?
    private var transitionSettings = PlaybackTransitionSettings.load()
    private var transitionSettingsObserver: NSObjectProtocol?
    private var queueRevision = UUID()
    private var transitionAttempts = PlaybackTransitionAttemptGate()
    private var currentResource: PlaybackResource?
    private var monitoredPlayer: AVPlayer?
    @Published private(set) var transitionStatus = ""

    init() {
        observeActivePlayer()
        transitionSettingsObserver = NotificationCenter.default.addObserver(
            forName: PlaybackTransitionSettings.changed, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transitionSettings = PlaybackTransitionSettings.load()
                self.cancelTransition(reason: self.transitionSettings.mode == .off ? "曲目过渡已关闭" : "播放设置已更改，改用普通切歌")
                self.transitionAttempts.reset()
            }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                let route = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in self?.audioEvent(type: type, options: options, route: route) }
            })
        }
        installCommands(); publishMetadata()
    }
    private func observeActivePlayer() {
        clearActivePlayerObservation()
        let observedPlayer = player
        monitoredPlayer = observedPlayer
        observations = [
            observedPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            observedPlayer.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        ]
        clock = observedPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
    private func clearActivePlayerObservation() {
        observations.forEach { $0.invalidate() }; observations.removeAll()
        if let clock, let monitoredPlayer { monitoredPlayer.removeTimeObserver(clock) }
        clock = nil; monitoredPlayer = nil
    }
    func play(_ songs: [Song], at: Int) {
        guard !songs.isEmpty else { stop(); return }
        queueRevision = UUID(); cancelTransition(reason: "播放队列已更改"); transitionAttempts.reset()
        queue = songs; index = min(max(at, 0), songs.count - 1)
        rebuildOrder(); select(index)
    }
    func toggle() {
        if wantsPlay || isPlaying { pause() } else { resume() }
    }
    func pause() {
        cancelTransition(reason: "已暂停 · 继续时正常切歌")
        interruptionResume = nil; wantsPlay = false; player.pause(); refresh()
    }
    func next() { advance(1) }
    func previous() {
        if elapsed > 3 { seek(to: 0) } else { advance(-1) }
    }
    func seek(to value: Double) {
        guard value.isFinite, duration > 0, player.currentItem?.status == .readyToPlay else { return }
        cancelTransition(reason: "定位后正常切歌")
        let time = min(max(value, 0), duration), token = generation
        ended = false
        listeningSession?.seek()
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor [weak self] in
                guard let self, done, self.generation == token else { return }
                self.elapsed = time
                if self.wantsPlay { self.player.play() }
                self.refresh()
            }
        }
    }
    /// Call when source configuration, source selection, quality, platform mode, or source-use policy changes.
    /// Cancels a credential/settings-bound speculative resolve without interrupting the playing item.
    func transitionResolutionContextDidChange() {
        queueRevision = UUID()
        cancelTransition(reason: "音源或播放设置已更改 · 普通切歌")
        transitionAttempts.reset()
    }
    func stop() {
        retire(); artwork = nil; artworkImage = nil; sourceLabel = ""; current = nil; queue = []; index = -1; order = []
        elapsed = 0; duration = 0; errorMessage = nil; qualityLabel = "原始音频"; isPreview = false
        publishMetadata()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func rebuildOrder() {
        let rebuilt = PlaybackPolicy.order(ids: queue.map(\.id), start: index, shuffle: shuffle)
        if rebuilt != order {
            queueRevision = UUID()
            cancelTransition(reason: "播放顺序已更改 · 普通切歌")
            transitionAttempts.reset()
        }
        order = rebuilt
    }
    private func advance(_ step: Int) {
        guard let position = order.firstIndex(of: index), !order.isEmpty else { return }
        var next = position + step
        if !order.indices.contains(next) {
            guard repeatMode != .sequential else { if step > 0 { pause() }; return }
            next = (next + order.count) % order.count
        }
        select(order[next])
    }
    private func select(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        retire(); transitionAttempts.reset(); currentResource = nil
        transitionCancelledForCurrentItem = false
        transitionStatus = transitionSettings.mode == .off ? "曲目过渡已关闭" : "等待下一首过渡"
        artwork = nil; artworkImage = nil; sourceLabel = ""; self.index = index; current = queue[index]; elapsed = 0
        duration = PlaybackPolicy.finite(queue[index].duration); qualityLabel = "原始音频"; isPreview = false
        errorMessage = nil; reportedStart = false; ended = false; wantsPlay = true; isLoading = true
        let song = queue[index], token = generation
        publishMetadata()
        loadArtwork(for: song, token: token)
        guard let resolve = resolver else { fail(.source); return }
        resolving = Task { [weak self] in
            do {
                let resource = try await resolve(song)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.resolving = nil
                try self.attach(resource, song: song, token: token)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if let musicError = error as? MusicError, case .unsupported(let message) = musicError {
                    self.retire()
                    let safe = PlaybackPolicy.metadata(message)
                    self.errorMessage = safe.isEmpty || safe == "—" ? PlaybackFailure.source.localizedDescription : safe
                    self.publishMetadata()
                } else if let error = error as? NeteaseError {
                    self.retire(); self.errorMessage = error.localizedDescription; self.publishMetadata()
                } else if let error = error as? EmbyFailure {
                    self.retire(); self.errorMessage = error.localizedDescription; self.publishMetadata()
                } else if let error = error as? SubsonicFailure {
                    self.retire(); self.errorMessage = error.localizedDescription; self.publishMetadata()
                } else { self.fail((error as? PlaybackFailure) ?? .source) }
            }
        }
    }
    private func loadArtwork(for song: Song, token: UUID) {
        guard let url = song.displayArtworkURL, ArtworkLoader.isAllowed(url) else { return }
        let identity = NowPlayingArtworkIdentity(generation: token, songID: song.id, url: url)
        artworkTask = Task { [weak self] in
            defer {
                if let self, identity.accepts(generation: self.generation, songID: self.current?.id, url: self.current?.displayArtworkURL) {
                    self.artworkTask = nil
                }
            }
            do {
                let data = try await ArtworkLoader.shared.data(url)
                try Task.checkCancellation()
                guard let image = ArtworkLoader.thumbnail(data), !Task.isCancelled,
                      let self, identity.accepts(generation: self.generation, songID: self.current?.id, url: self.current?.displayArtworkURL) else { return }
                // The system's synchronous callback owns only this bounded, immutable image.
                self.artworkImage = image
                self.artwork = (identity, MPMediaItemArtwork(boundsSize: image.size) { [image] _ in image })
                self.publishMetadata()
            } catch { /* Optional public artwork must never change audio or playback errors. */ }
        }
    }
    private func attach(_ resource: PlaybackResource, song: Song, token: UUID) throws {
        try PlaybackPolicy.validateURL(resource.url, local: song.platform == .local)
        if let mime = resource.mimeType?.lowercased(), mime.contains("mpegurl") || mime.contains("dash") { throw PlaybackFailure.format }
        let asset: AVURLAsset
        if resource.requiresResourceLoader || !resource.headers.isEmpty || song.platform == .emby {
            let bridge = try AuthenticatedAudioLoader(resource) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail(error)
                }
            }
            loader = bridge; asset = bridge.makeAsset()
        } else { asset = AVURLAsset(url: resource.url) }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        currentResource = resource
        qualityLabel = PlaybackPolicy.metadata(resource.displayQuality); isPreview = resource.isPreview; sourceLabel = PlaybackPolicy.metadata(resource.sourceLabel ?? "")
        listeningScope = song.platform == .netease && !resource.isPreview ? resource.neteaseHistoryScope : nil
        listeningCycleID = UUID(); listeningSession = nil
        player.replaceCurrentItem(with: item)
        anchorOnsetCapture.start(on: item, enabled: transitionSettings.mode == .beat && !resource.isPreview)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == token, self.player.currentItem === item else { return }
                if item.status == .failed { self.fail(.format) } else { self.refresh() }
            }
        }
        for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime] {
            itemNotifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if name == .AVPlayerItemDidPlayToEndTime { self.didEnd() } else { self.fail(.network) }
                }
            })
        }
        if wantsPlay { try activate(); player.play() }
        refresh()
    }
    private func scheduleTransitionPreloadIfNeeded() {
        guard transitionSettings.mode != .off, wantsPlay, !ended, current != nil,
              !transitionCancelledForCurrentItem,
              transitionSettings == PlaybackTransitionSettings.load(),
              currentResource != nil, pendingTicket == nil, pendingDeck == nil,
              preloadingTask == nil, resolvingTicket == nil,
              let resolve = resolver else { return }
        if repeatMode == .one { transitionStatus = "单曲循环 · 不做曲目过渡"; return }
        guard let mediaDuration = player.currentItem?.duration.seconds,
              PlaybackTransitionMath.eligible(duration: mediaDuration, fade: transitionSettings.seconds) else {
            transitionStatus = "正常切歌 · 时长未知或曲目过短"; return
        }
        guard let next = PlaybackTransitionMath.nextIndex(
            order: order, current: index, wraps: repeatMode == .all, repeatsOne: repeatMode == .one
        ), queue.indices.contains(next) else { return }
        let position = player.currentTime().seconds
        let remaining = mediaDuration - position
        let fade = PlaybackTransitionMath.boundedFade(transitionSettings.seconds)
        guard position.isFinite, remaining.isFinite, remaining > 0,
              remaining <= max(8, fade + 7), transitionAttempts.claim(next) else { return }
        let song = queue[next]
        let ticket = PlaybackTransitionTicket(generation: generation, queueRevision: queueRevision,
                                              targetIndex: next, songID: song.id)
        pendingTicket = ticket; resolvingTicket = ticket; pendingSong = song; pendingPrepared = false
        pendingPlan = nil; pendingIncomingOffset = 0; transitionStarting = false; fading = false
        transitionStatus = transitionSettings.mode == .beat ? "准备有限起音采样 · 不保证鼓点同步…" : "预加载下一首以准备淡化…"
        preloadingTask = Task { [weak self] in
            // Do not retain the store while a non-cooperative resolver is suspended.
            do {
                let resource = try await resolve(song)
                try Task.checkCancellation()
                guard let self, self.transitionTicketIsCurrent(ticket) else { return }
                await self.prepareTransition(ticket, song: song, resource: resource)
            } catch {
                guard let self, self.pendingTicket == ticket else { return }
                self.cancelTransition(reason: "正常切歌 · 下一首预加载不可用")
            }
        }
    }
    private func prepareTransition(_ ticket: PlaybackTransitionTicket, song: Song,
                                   resource: PlaybackResource) async {
        var candidate: PlaybackTransitionDeck?
        defer {
            if resolvingTicket == ticket { resolvingTicket = nil; preloadingTask = nil }
        }
        do {
            try Task.checkCancellation()
            guard transitionTicketIsCurrent(ticket) else { return }
            let deck = PlaybackTransitionDeck(); candidate = deck
            deck.onEvent = { [weak self] deck, event in self?.transitionDeck(deck, received: event) }
            try deck.attach(resource, song: song)
            guard transitionTicketIsCurrent(ticket) else { deck.dispose(); return }
            pendingDeck = deck
            let position = player.currentTime().seconds
            let mediaDuration = player.currentItem?.duration.seconds ?? .nan
            let nominalStart = mediaDuration - PlaybackTransitionMath.boundedFade(transitionSettings.seconds)
            guard position.isFinite, nominalStart.isFinite, nominalStart - position > 1 else {
                cancelTransition(reason: "正常切歌 · 准备时间不足"); return
            }
            let deadline = ProcessInfo.processInfo.systemUptime + min(6, nominalStart - position - 0.15)
            preparationDeadlineTask?.cancel()
            preparationDeadlineTask = Task { [weak self] in
                let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard let self, self.pendingTicket == ticket, !self.pendingPrepared else { return }
                self.cancelTransition(reason: "正常切歌 · 准备超时")
            }
            let beatEnabled = transitionSettings.mode == .beat && !resource.isPreview && currentResource?.isPreview == false
            guard let incomingItem = deck.player.currentItem else { throw PlaybackFailure.source }
            deck.onsetCapture.start(on: incomingItem, enabled: beatEnabled)
            // Readiness is required; unsupported/slow tap installation must not delay fixed fade.
            while !deck.isReady {
                try Task.checkCancellation()
                guard transitionTicketIsCurrent(ticket), pendingDeck === deck,
                      ProcessInfo.processInfo.systemUptime < deadline - PlaybackTransitionPreparationPolicy.restoreBudget else {
                    throw PlaybackFailure.source
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let installationDeadline = min(deadline - PlaybackTransitionPreparationPolicy.restoreBudget,
                ProcessInfo.processInfo.systemUptime + 0.5)
            while beatEnabled && deck.onsetCapture.installing && ProcessInfo.processInfo.systemUptime < installationDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
                guard transitionTicketIsCurrent(ticket), pendingDeck === deck else { deck.dispose(); return }
            }
            if deck.onsetCapture.installing { deck.onsetCapture.stop() }
            var plan: BeatTransitionPlan?
            var status = "固定淡化 · 已准备"
            if beatEnabled, let outgoing = currentResource {
                if outgoing.url.isFileURL && resource.url.isFileURL && outgoing.headers.isEmpty && resource.headers.isEmpty
                    && !outgoing.requiresResourceLoader && !resource.requiresResourceLoader {
                    let result = await BeatTransitionAnalyzer.analyze(outgoing: outgoing, incoming: resource,
                        duration: mediaDuration, fade: transitionSettings.seconds)
                    plan = result.plan; status = result.message
                } else {
                    let budget = min(PlaybackTransitionPreparationPolicy.probeBudget(
                        position: player.currentTime().seconds, duration: mediaDuration, fade: transitionSettings.seconds),
                        max(0, deadline - ProcessInfo.processInfo.systemUptime - PlaybackTransitionPreparationPolicy.restoreBudget))
                    let incoming = await deck.probeHead(budget: budget)
                    try Task.checkCancellation()
                    guard transitionTicketIsCurrent(ticket), pendingDeck === deck else { deck.dispose(); return }
                    let outgoingEvidence = activeOnsetCapture.tap?.snapshot() ?? []
                    plan = BeatOnsetAnalysis.plan(outgoing: outgoingEvidence, incoming: incoming,
                        duration: mediaDuration, requestedFade: transitionSettings.seconds)
                    status = plan == nil ? "固定淡化 · 流媒体起音证据不足" : "机会式起音对齐 · 非持续节拍同步"
                }
            }
            try Task.checkCancellation()
            guard transitionTicketIsCurrent(ticket), pendingDeck === deck else { deck.dispose(); return }
            if let proposed = plan, !PlaybackTransitionPreparationPolicy.acceptsPlan(proposed, position: player.currentTime().seconds) {
                plan = nil; status = "固定淡化 · 起音计划已错过"
            }
            pendingPlan = plan
            pendingIncomingOffset = plan?.incomingStart ?? 0
            // A probe may have moved the item even without usable evidence. Always confirm exact restore.
            let sought = await deck.seek(to: pendingIncomingOffset,
                deadline: min(deadline, ProcessInfo.processInfo.systemUptime + PlaybackTransitionPreparationPolicy.restoreBudget))
            try Task.checkCancellation()
            guard transitionTicketIsCurrent(ticket), pendingDeck === deck else { deck.dispose(); return }
            guard sought else { cancelTransition(reason: "正常切歌 · 起音回位失败或超时"); return }
            if let proposed = pendingPlan, proposed.outgoingStart <= player.currentTime().seconds {
                // Never backdate a plan or call a partially restored offset fixed-from-zero.
                pendingPlan = nil; pendingIncomingOffset = 0
                let restored = await deck.seek(to: 0,
                    deadline: min(deadline, ProcessInfo.processInfo.systemUptime + PlaybackTransitionPreparationPolicy.restoreBudget))
                try Task.checkCancellation()
                guard transitionTicketIsCurrent(ticket), pendingDeck === deck else { deck.dispose(); return }
                guard restored else { cancelTransition(reason: "正常切歌 · 回零失败"); return }
                status = "固定淡化 · 起音计划已错过"
            }
            guard PlaybackTransitionPreparationPolicy.canPrepare(
                current: transitionTicketIsCurrent(ticket) && pendingDeck === deck, restored: sought,
                ready: deck.isReady, position: player.currentTime().seconds, nominalStart: nominalStart,
                now: ProcessInfo.processInfo.systemUptime, deadline: deadline) else {
                cancelTransition(reason: "正常切歌 · 已错过准备窗口"); return
            }
            preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
            pendingPrepared = true
            transitionStatus = status
            candidate = nil
            startFadeTimer(ticket)
            updateTransition()
        } catch {
            candidate?.dispose()
            guard pendingTicket == ticket else { return }
            cancelTransition(reason: "正常切歌 · 下一首预加载不可用")
        }
    }
    private func transitionTicketIsCurrent(_ ticket: PlaybackTransitionTicket) -> Bool {
        guard let pendingTicket, pendingTicket == ticket else { return false }
        return ticket.generation == generation && ticket.queueRevision == queueRevision &&
            queue.indices.contains(ticket.targetIndex) && queue[ticket.targetIndex].id == ticket.songID &&
            PlaybackTransitionMath.nextIndex(order: order, current: index, wraps: repeatMode == .all,
                                            repeatsOne: repeatMode == .one) == ticket.targetIndex &&
            wantsPlay && !transitionCancelledForCurrentItem && transitionSettings.mode != .off &&
            transitionSettings == PlaybackTransitionSettings.load()
    }
    private func transitionDeck(_ deck: PlaybackTransitionDeck, received event: PlaybackTransitionDeck.Event) {
        if deck === pendingDeck {
            switch event {
            case .changed: updateTransition()
            case .ended: cancelTransition(reason: "正常切歌 · 预加载音频已结束")
            case .failed:
                cancelTransition(reason: "正常切歌 · 预加载音频不可用")
            }
        } else if deck === activeDeck {
            switch event {
            case .changed: refresh()
            case .ended: didEnd()
            case .failed(let error): fail(error)
            }
        }
    }
    private func cancelTransition(reason: String) {
        // Invalidate identities before disposing: cancellation can enqueue callbacks.
        // A pause/seek/settings change conservatively disables overlap for this item.
        transitionCancelledForCurrentItem = true; transitionStartDeadline = 0
        preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
        activeOnsetCapture.stop()
        preloadingTask?.cancel(); preloadingTask = nil; resolvingTicket = nil
        let cancelledDeck = pendingDeck
        pendingDeck = nil; pendingSong = nil; pendingTicket = nil; pendingPlan = nil
        pendingIncomingOffset = 0; pendingPrepared = false
        transitionStarting = false; fading = false; fadeStart = 0; fadeDuration = 0
        stopFadeTimer()
        cancelledDeck?.dispose()
        player.volume = 1
        transitionStatus = reason
    }
    private func updateTransition() {
        guard let ticket = pendingTicket else { stopFadeTimer(); return }
        guard transitionTicketIsCurrent(ticket) else {
            cancelTransition(reason: "正常切歌 · 过渡状态已失效"); return
        }
        guard pendingPrepared, let incoming = pendingDeck else { return }
        guard !incoming.hasEnded else { cancelTransition(reason: "正常切歌 · 下一首已结束"); return }
        guard incoming.isReady else { return }
        let requestedFade = pendingPlan?.fadeSeconds ?? PlaybackTransitionMath.boundedFade(transitionSettings.seconds)
        guard let incomingDuration = incoming.finiteDuration,
              PlaybackTransitionMath.eligible(duration: incomingDuration, fade: requestedFade) else {
            cancelTransition(reason: "正常切歌 · 下一首时长未知或过短"); return
        }
        let now = player.currentTime().seconds
        let mediaDuration = player.currentItem?.duration.seconds ?? .nan
        guard now.isFinite, mediaDuration.isFinite, mediaDuration > 0 else {
            cancelTransition(reason: "正常切歌 · 播放时钟不可用"); return
        }
        if now >= mediaDuration {
            guard pendingPlan == nil || fading else {
                cancelTransition(reason: "正常切歌 · 自然结束已错过起音计划"); return
            }
            incoming.player.play()
            promoteIncoming(ticket, naturalEnd: true)
            return
        }
        // Do not let one deck run away while the other stalls.
        if fading && (!incoming.isActuallyPlaying || player.timeControlStatus != .playing) {
            cancelTransition(reason: "正常切歌 · 缓冲中断淡化"); return
        }
        let nominalStart = pendingPlan?.outgoingStart ?? mediaDuration - PlaybackTransitionMath.boundedFade(transitionSettings.seconds)
        guard nominalStart.isFinite else { return }
        if !fading, pendingPlan != nil,
           PlaybackTransitionPreparationPolicy.missedPlan(start: nominalStart, position: now) {
            cancelTransition(reason: "正常切歌 · 已错过起音计划，不回填"); return
        }
        if !transitionStarting && !fading && now >= nominalStart {
            guard player.timeControlStatus == .playing else { return }
            do { try activate() }
            catch { cancelTransition(reason: "正常切歌 · 无法启动第二播放器"); return }
            incoming.player.volume = 0
            transitionStarting = true
            transitionStartDeadline = ProcessInfo.processInfo.systemUptime + 2
            startFadeTimer(ticket)
            transitionStatus = "等待下一首开始 · 尚未淡化"
            incoming.player.play()
        }
        if transitionStarting && incoming.isActuallyPlaying {
            transitionStarting = false; fading = true
            fadeStart = now
            fadeDuration = min(requestedFade, max(0.08, mediaDuration - fadeStart))
            transitionStatus = pendingPlan == nil ? "固定交叉淡化中" : "机会式起音衔接 · 非节拍同步"
        } else if transitionStarting && ProcessInfo.processInfo.systemUptime >= transitionStartDeadline {
            cancelTransition(reason: "正常切歌 · 下一首启动超时"); return
        }
        guard fading, let progress = PlaybackTransitionMath.progress(position: now, start: fadeStart, duration: fadeDuration) else { return }
        let gains = PlaybackTransitionMath.gains(progress: progress, curve: transitionSettings.curve)
        player.volume = gains.outgoing; incoming.player.volume = gains.incoming
        if progress >= 1 { promoteIncoming(ticket) }
    }
    private func startFadeTimer(_ ticket: PlaybackTransitionTicket) {
        stopFadeTimer()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingTicket == ticket else { return }
                self.updateTransition()
            }
        }
        RunLoop.main.add(timer, forMode: .common); fadeTimer = timer
    }
    private func promoteIncoming(_ ticket: PlaybackTransitionTicket, naturalEnd: Bool = false) {
        guard transitionTicketIsCurrent(ticket), let incoming = pendingDeck,
              incoming.isReady, !incoming.hasEnded,
              let song = pendingSong, let resource = incoming.resource else {
            cancelTransition(reason: "正常切歌 · 过渡状态已失效"); return
        }
        let oldDeck = activeDeck
        let outgoingPlayer = player
        clearActivePlayerObservation()
        itemObservation?.invalidate(); itemObservation = nil
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }; itemNotifications.removeAll()
        // Retire the outgoing identity before pause/replacement can enqueue events.
        generation = UUID()
        activeOnsetCapture.stop()
        incoming.onsetCapture.resetWindow()
        preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
        outgoingPlayer.pause(); outgoingPlayer.volume = 1; outgoingPlayer.cancelPendingPrerolls()
        outgoingPlayer.currentItem?.cancelPendingSeeks(); outgoingPlayer.replaceCurrentItem(with: nil)
        loader?.invalidate(); loader = nil
        finishListening(naturalEnd: naturalEnd)
        listeningScope = nil
        preloadingTask?.cancel(); preloadingTask = nil; resolvingTicket = nil
        pendingDeck = nil; pendingTicket = nil; pendingSong = nil; pendingPlan = nil
        pendingIncomingOffset = 0; pendingPrepared = false
        transitionStarting = false; fading = false; transitionStartDeadline = 0
        fadeStart = 0; fadeDuration = 0; stopFadeTimer()
        activeDeck = incoming; incoming.player.volume = 1
        oldDeck?.dispose()
        currentResource = resource
        index = ticket.targetIndex; current = song
        elapsed = PlaybackPolicy.finite(incoming.player.currentTime().seconds)
        duration = incoming.finiteDuration ?? PlaybackPolicy.finite(song.duration)
        qualityLabel = PlaybackPolicy.metadata(resource.displayQuality)
        sourceLabel = PlaybackPolicy.metadata(resource.sourceLabel ?? "")
        isPreview = resource.isPreview; errorMessage = nil
        reportedStart = false; ended = false; wantsPlay = true
        listeningScope = song.platform == .netease && !resource.isPreview ? resource.neteaseHistoryScope : nil
        listeningCycleID = UUID(); listeningSession = nil
        artworkTask?.cancel(); artworkTask = nil; artwork = nil; artworkImage = nil
        transitionAttempts.reset(); transitionCancelledForCurrentItem = false; transitionStatus = ""
        loadArtwork(for: song, token: generation)
        observeActivePlayer(); publishMetadata(); refresh()
    }
    private func stopFadeTimer() {
        fadeTimer?.invalidate(); fadeTimer = nil
    }
    private func activate() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default)
        try audio.setActive(true)
    }
    private func resume() {
        interruptionResume = nil
        guard current != nil else { return }
        if errorMessage != nil || ended { select(index); return }
        wantsPlay = true
        do { if player.currentItem != nil { try activate(); player.play() }; refresh() }
        catch { fail(.network) }
    }
    private func didEnd() {
        guard !ended else { return }
        // Natural end may beat the final timer tick. Reuse only a ready, finite,
        // non-ended deck with a still-current queue/settings ticket.
        if let ticket = pendingTicket, let incoming = pendingDeck,
           (pendingPlan == nil || fading), transitionTicketIsCurrent(ticket),
           PlaybackTransitionMath.shouldPromoteAtEnd(
               wantsPlay: wantsPlay, incomingPrepared: pendingPrepared, repeatsOne: repeatMode == .one,
               incomingReady: incoming.isReady,
               incomingEligible: incoming.finiteDuration.map {
                   PlaybackTransitionMath.eligible(duration: $0, fade: transitionSettings.seconds)
               } ?? false, incomingEnded: incoming.hasEnded
           ) {
            incoming.player.volume = 1
            incoming.player.play()
            promoteIncoming(ticket, naturalEnd: true)
            return
        }
        // A late/failed preparation cannot outlive normal repeat/queue advancement.
        cancelTransition(reason: "正常切歌 · 过渡未及时就绪")
        finishListening(naturalEnd: true)
        listeningCycleID = UUID()
        ended = true
        guard wantsPlay else { refresh(); return }
        if repeatMode == .one { seek(to: 0); return }
        if repeatMode == .all || order.last != index { advance(1) }
        else { wantsPlay = false; player.pause(); elapsed = duration; refresh() }
    }
    private func refresh() {
        guard current != nil else { isPlaying = false; isLoading = false; return }
        if let item = player.currentItem {
            let seconds = item.duration.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
            elapsed = min(PlaybackPolicy.finite(player.currentTime().seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        }
        isPlaying = wantsPlay && player.timeControlStatus == .playing && player.rate > 0
        if transitionSettings.mode == .beat, !transitionCancelledForCurrentItem,
           let seconds = player.currentItem?.duration.seconds {
            activeOnsetCapture.armTail(duration: seconds, fade: transitionSettings.seconds)
        }
        sampleListening()
        isLoading = wantsPlay && (resolving != nil || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        publishMetadata()
        if isPlaying, !reportedStart, let song = current { reportedStart = true; onStarted?(song) }
        guard wantsPlay else { return }
        updateTransition()
        scheduleTransitionPreloadIfNeeded()
    }
    private func sampleListening() {
        guard reportsListening, let song = current, let scope = listeningScope, !ended else { return }
        if listeningSession == nil {
            listeningSession = ListeningSession(song: song, scope: scope,
                duration: duration > 0 ? duration : nil, id: listeningCycleID)
        }
        if listeningSession?.sample(position: elapsed, monotonic: ProcessInfo.processInfo.systemUptime, isPlaying: isPlaying) == true,
           let session = listeningSession { onListeningStarted?(session) }
    }
    private func finishListening(naturalEnd: Bool) {
        guard var session = listeningSession else { return }
        listeningSession = nil
        if let snapshot = session.finish(), reportsListening { onListeningFinished?(snapshot, naturalEnd) }
    }
    private func retire() {
        finishListening(naturalEnd: false)
        listeningScope = nil
        generation = UUID(); resolving?.cancel(); resolving = nil
        artworkTask?.cancel(); artworkTask = nil
        interruptionResume = nil; wantsPlay = false; isPlaying = false; isLoading = false
        cancelTransition(reason: "普通切歌")
        itemObservation?.invalidate(); itemObservation = nil
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }; itemNotifications = []
        clearActivePlayerObservation()
        let outgoing = player
        outgoing.pause(); outgoing.volume = 1; outgoing.currentItem?.cancelPendingSeeks()
        outgoing.replaceCurrentItem(with: nil)
        loader?.invalidate(); loader = nil; currentResource = nil
        let oldDeck = activeDeck; activeDeck = nil; oldDeck?.dispose()
        observeActivePlayer()
    }
    private func fail(_ error: PlaybackFailure) {
        retire(); errorMessage = error.localizedDescription; publishMetadata()
    }
    private func audioEvent(type: UInt?, options: UInt, route: UInt?) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            cancelTransition(reason: "音频中断 · 恢复后正常切歌")
            interruptionResume = wantsPlay ? generation : nil
            wantsPlay = false; player.pause(); refresh()
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let resumeAllowed = interruptionResume == generation && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            interruptionResume = nil
            if resumeAllowed { resume() }
        }
        if route == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || route == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue { pause() }
    }
    private func publishMetadata() {
        let center = MPRemoteCommandCenter.shared()
        for (command, _) in commands { command.isEnabled = current != nil }
        center.changePlaybackPositionCommand.isEnabled = current != nil && duration > 0 && player.currentItem?.status == .readyToPlay
        guard let song = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: PlaybackPolicy.metadata(song.title),
            MPMediaItemPropertyArtist: PlaybackPolicy.metadata(song.artist),
            MPMediaItemPropertyAlbumTitle: PlaybackPolicy.metadata(song.album),
            MPMediaItemPropertyPlaybackDuration: PlaybackPolicy.finite(duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: PlaybackPolicy.finite(elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artwork, artwork.identity.belongsTo(songID: song.id, url: song.displayArtworkURL) {
            info[MPMediaItemPropertyArtwork] = artwork.value
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerStore) -> Void) {
        let target = command.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
            Task { @MainActor [weak self] in if let self { action(self) } }
            return .success
        }
        commands.append((command, target))
    }
    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { $0.resume() }; bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.toggle() }; bind(center.stopCommand) { $0.stop() }
        bind(center.nextTrackCommand) { $0.next() }; bind(center.previousTrackCommand) { $0.previous() }
        let command = center.changePlaybackPositionCommand
        let target = command.addTarget { [weak self] event -> MPRemoteCommandHandlerStatus in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
        commands.append((command, target))
    }
    deinit {
        resolving?.cancel(); artworkTask?.cancel(); preloadingTask?.cancel()
        preparationDeadlineTask?.cancel()
        // Nonisolated destructor: capture owned resources, never capture the dying store.
        // Normal retire/cancel paths detach synchronously; this is final-release fallback only.
        let finalAnchorCapture = anchorOnsetCapture
        let finalPendingDeck = pendingDeck, finalActiveDeck = activeDeck
        let finalAnchorPlayer = anchorPlayer
        Task { @MainActor in
            finalAnchorCapture.stop()
            finalPendingDeck?.dispose(); finalActiveDeck?.dispose()
            finalAnchorPlayer.pause()
        }
        itemObservation?.invalidate(); observations.forEach { $0.invalidate() }
        if let clock, let monitoredPlayer { monitoredPlayer.removeTimeObserver(clock) }
        fadeTimer?.invalidate()
        if let transitionSettingsObserver { NotificationCenter.default.removeObserver(transitionSettingsObserver) }
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        commands.forEach { $0.0.removeTarget($0.1) }
        anchorPlayer.pause(); loader?.invalidate()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

#if DEBUG
@MainActor extension PlayerStore {
    func seedPolishFixture() {
        guard UIPolishFixture.enabled else { return }
        queue = UIPolishFixture.songs; index = 0; current = queue[0]; elapsed = 25; duration = 246
        qualityLabel = "高品质 · MP3 · 320 kbps"; sourceLabel = "原生界面测试数据"; artworkImage = UIPolishFixture.image(UIPolishFixture.url("a"))
        if let image = artworkImage, let song = current {
            let identity = NowPlayingArtworkIdentity(generation: generation, songID: song.id, url: song.displayArtworkURL!)
            artwork = (identity, MPMediaItemArtwork(boundsSize: image.size) { [image] _ in image })
        }
        publishMetadata()
    }
}
#endif
