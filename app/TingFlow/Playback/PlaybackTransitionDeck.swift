import AVFoundation

/// One deck owns its item, credential-bound loader, KVO, notifications and clock.
/// PlayerStore keeps at most two decks. Call dispose() before releasing/replacing one.
@MainActor final class PlaybackTransitionDeck {
    enum Event { case changed, ended, failed(PlaybackFailure) }
    let id = UUID()
    let player = AVPlayer()
    private(set) var resource: PlaybackResource?
    private var loader: AuthenticatedAudioLoader?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var clock: Any?
    private var disposed = false
    private(set) var hasEnded = false
    let onsetCapture = PlaybackOnsetCapture()
    private var probeBoundary: Any?
    private var probeTimeout: Task<Void, Never>?
    private var probeOperation: UUID?
    private var probeCompletion: (([BeatOnset]) -> Void)?
    private var seekOperation: UUID?
    private var seekCompletion: ((Bool) -> Void)?
    private var seekTimeout: Task<Void, Never>?
    var onEvent: ((PlaybackTransitionDeck, Event) -> Void)?
    var finiteDuration: Double? {
        guard let item = player.currentItem, item.status == .readyToPlay else { return nil }
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
    var isActuallyPlaying: Bool { player.timeControlStatus == .playing && player.rate > 0 }
    var isReady: Bool { player.currentItem?.status == .readyToPlay }
    init() { player.automaticallyWaitsToMinimizeStalling = true }
    /// Completion, cancellation, disposal and timeout all resolve this operation exactly once.
    func seek(to seconds: Double, deadline: Double) async -> Bool {
        finishSeek(false)
        guard !disposed, isReady, seconds.isFinite, seconds >= 0,
              deadline > ProcessInfo.processInfo.systemUptime, let item = player.currentItem else { return false }
        let operation = UUID()
        seekOperation = operation
        return await withCheckedContinuation { continuation in
            seekCompletion = { continuation.resume(returning: $0) }
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            seekTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(delay, 3) * 1_000_000_000))
                guard !Task.isCancelled, let self,
                      PlaybackTransitionPreparationPolicy.isCurrent(operation, self.seekOperation) else { return }
                self.finishSeek(false)
                item.cancelPendingSeeks()
            }
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] completed in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item,
                          PlaybackTransitionPreparationPolicy.isCurrent(operation, self.seekOperation) else { return }
                    let accepted = !self.disposed && self.player.currentItem === item &&
                        PlaybackTransitionPreparationPolicy.acceptsRewind(operation: operation,
                            current: self.seekOperation, completed: completed,
                            position: self.player.currentTime().seconds, target: seconds,
                            now: ProcessInfo.processInfo.systemUptime, deadline: deadline)
                    self.finishSeek(accepted)
                }
            }
        }
    }
    private func finishSeek(_ success: Bool) {
        seekOperation = nil
        seekTimeout?.cancel(); seekTimeout = nil
        let completion = seekCompletion; seekCompletion = nil
        completion?(success)
    }
    /// No metadata/history hooks: only this unpromoted item's existing player runs at zero gain.
    /// Both termination paths snapshot before clear/pause; disposal discards the snapshot.
    func probeHead(budget: Double) async -> [BeatOnset] {
        guard !disposed, isReady, budget.isFinite, budget > 0,
              let tap = onsetCapture.tap, tap.arm(start: 0, seconds: 3) else { return [] }
        let operation = UUID()
        probeOperation = operation
        player.volume = 0
        return await withCheckedContinuation { continuation in
            probeCompletion = { continuation.resume(returning: $0) }
            probeBoundary = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: 3, preferredTimescale: 600))], queue: .main) { [weak self] in
                Task { @MainActor [weak self] in self?.finishProbe(operation: operation) }
            }
            let started = ProcessInfo.processInfo.systemUptime
            probeTimeout = Task { [weak self] in
                // Monotonic wall-clock bound still fires when media time stalls or callbacks are absent.
                while !Task.isCancelled {
                    guard let self, self.probeOperation == operation else { return }
                    if !PlaybackTransitionPreparationPolicy.continueProbe(media: self.player.currentTime().seconds,
                        now: ProcessInfo.processInfo.systemUptime, started: started, budget: budget) {
                        self.finishProbe(operation: operation); return
                    }
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                }
            }
            player.play()
        }
    }
    private func finishProbe(operation: UUID?, discard: Bool = false) {
        guard let operation, self.probeOperation == operation else { return }
        self.probeOperation = nil
        let evidence = discard ? [] : (onsetCapture.tap?.snapshot() ?? [])
        onsetCapture.resetWindow()
        if let probeBoundary { player.removeTimeObserver(probeBoundary); self.probeBoundary = nil }
        probeTimeout?.cancel(); probeTimeout = nil
        player.pause()
        let completion = probeCompletion; probeCompletion = nil
        completion?(evidence)
    }
    func attach(_ resource: PlaybackResource, song: Song) throws {
        guard !disposed, player.currentItem == nil, self.resource == nil else { throw PlaybackFailure.source }
        try PlaybackPolicy.validateURL(resource.url, local: song.platform == .local)
        if let mime = resource.mimeType?.lowercased(), mime.contains("mpegurl") || mime.contains("dash") { throw PlaybackFailure.format }
        self.resource = resource
        let asset: AVURLAsset
        if resource.requiresResourceLoader || !resource.headers.isEmpty || song.platform == .emby {
            let bridge = try AuthenticatedAudioLoader(resource) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, !self.disposed else { return }
                    self.onEvent?(self, .failed(error))
                }
            }
            loader = bridge; asset = bridge.makeAsset()
        } else { asset = AVURLAsset(url: resource.url) }
        let item = AVPlayerItem(asset: asset)
        // Preloading must not fetch an entire file. AVFoundation still controls codec/seek metadata reads.
        item.preferredForwardBufferDuration = 5
        player.replaceCurrentItem(with: item)
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, !self.disposed, let item, self.player.currentItem === item else { return }
                    self.onEvent?(self, item.status == .failed ? .failed(.format) : .changed)
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.changed() }
            },
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.changed() }
            }
        ]
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.changed() }
        }
        for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.disposed, self.player.currentItem === item else { return }
                    if name == .AVPlayerItemDidPlayToEndTime { self.hasEnded = true }
                    self.onEvent?(self, name == .AVPlayerItemDidPlayToEndTime ? .ended : .failed(.network))
                }
            })
        }
    }
    private func changed() { if !disposed { onEvent?(self, .changed) } }
    func dispose() {
        guard !disposed else { return }
        disposed = true; onEvent = nil
        finishProbe(operation: probeOperation, discard: true)
        onsetCapture.stop()
        finishSeek(false)
        observations.forEach { $0.invalidate() }; observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        if let clock { player.removeTimeObserver(clock); self.clock = nil }
        player.pause(); player.cancelPendingPrerolls(); player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil); loader?.invalidate(); loader = nil; resource = nil
    }
    deinit {
        observations.forEach { $0.invalidate() }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        if let clock { player.removeTimeObserver(clock) }
        player.pause(); loader?.invalidate()
    }
}

/// One existing item's tap and one installation task. Context replacement invalidates first;
/// even an installation that ignores cancellation must detach its returned stale tap.
@MainActor final class PlaybackOnsetCapture {
    private(set) var tap: PlaybackOnsetTap?
    private(set) var installing = false
    private var installation: Task<Void, Never>?
    private var operation: UUID?
    private weak var item: AVPlayerItem?
    private var armedDuration: Double?
    func start(on item: AVPlayerItem, enabled: Bool) {
        stop()
        guard enabled else { return }
        let token = UUID()
        operation = token; self.item = item; installing = true
        installation = Task { [weak self, weak item] in
            guard let item else { return }
            let result = await PlaybackOnsetTap.install(on: item, enabled: true)
            guard !Task.isCancelled, let self,
                  PlaybackTransitionPreparationPolicy.isCurrent(token, self.operation), self.item === item else {
                result?.teardown(); return
            }
            self.tap = result; self.installing = false; self.installation = nil
        }
    }
    func armTail(duration: Double, fade: Double) {
        guard let tap, duration.isFinite, duration > 0, armedDuration != duration else { return }
        armedDuration = duration
        let seconds = min(12, PlaybackTransitionMath.boundedFade(fade) + 1)
        tap.arm(start: max(0, duration - seconds), seconds: min(seconds, duration))
    }
    func resetWindow() { tap?.clear(); armedDuration = nil }
    func stop() {
        operation = nil
        installation?.cancel(); installation = nil; installing = false
        tap?.teardown(); tap = nil; item = nil; armedDuration = nil
    }
}
