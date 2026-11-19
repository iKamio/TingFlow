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
    @Published var shuffle = false { didSet { rebuildOrder() } }
    @Published var repeatMode: RepeatMode = .sequential
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

    private let player = AVPlayer()
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

    init() {
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        ]
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
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
    func play(_ songs: [Song], at: Int) {
        guard !songs.isEmpty else { stop(); return }
        queue = songs; index = min(max(at, 0), songs.count - 1)
        rebuildOrder(); select(index)
    }
    func toggle() {
        if wantsPlay || isPlaying { pause() } else { resume() }
    }
    func pause() {
        interruptionResume = nil; wantsPlay = false; player.pause(); refresh()
    }
    func next() { advance(1) }
    func previous() {
        if elapsed > 3 { seek(to: 0) } else { advance(-1) }
    }
    func seek(to value: Double) {
        guard value.isFinite, duration > 0, player.currentItem?.status == .readyToPlay else { return }
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
    func stop() {
        retire(); artwork = nil; artworkImage = nil; sourceLabel = ""; current = nil; queue = []; index = -1; order = []
        elapsed = 0; duration = 0; errorMessage = nil; qualityLabel = "原始音频"; isPreview = false
        publishMetadata()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func rebuildOrder() { order = PlaybackPolicy.order(ids: queue.map(\.id), start: index, shuffle: shuffle) }
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
        retire(); artwork = nil; artworkImage = nil; sourceLabel = ""; self.index = index; current = queue[index]; elapsed = 0
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
        guard let url = song.artworkURL, ArtworkLoader.isAllowed(url) else { return }
        let identity = NowPlayingArtworkIdentity(generation: token, songID: song.id, url: url)
        artworkTask = Task { [weak self] in
            defer {
                if let self, identity.accepts(generation: self.generation, songID: self.current?.id, url: self.current?.artworkURL) {
                    self.artworkTask = nil
                }
            }
            do {
                let data = try await ArtworkLoader.shared.data(url)
                try Task.checkCancellation()
                guard let image = ArtworkLoader.thumbnail(data), !Task.isCancelled,
                      let self, identity.accepts(generation: self.generation, songID: self.current?.id, url: self.current?.artworkURL) else { return }
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
        qualityLabel = PlaybackPolicy.metadata(resource.displayQuality); isPreview = resource.isPreview; sourceLabel = PlaybackPolicy.metadata(resource.sourceLabel ?? "")
        listeningScope = song.platform == .netease && !resource.isPreview ? resource.neteaseHistoryScope : nil
        listeningCycleID = UUID(); listeningSession = nil
        player.replaceCurrentItem(with: item)
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
        sampleListening()
        isLoading = wantsPlay && (resolving != nil || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        publishMetadata()
        if isPlaying, !reportedStart, let song = current { reportedStart = true; onStarted?(song) }
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
        // Preserve an accepted current cover on audio failure; select/stop clear it explicitly.
        interruptionResume = nil; wantsPlay = false; isPlaying = false; isLoading = false
        itemObservation?.invalidate(); itemObservation = nil
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }; itemNotifications = []
        player.pause(); player.replaceCurrentItem(with: nil)
        loader?.invalidate(); loader = nil
    }
    private func fail(_ error: PlaybackFailure) {
        retire(); errorMessage = error.localizedDescription; publishMetadata()
    }
    private func audioEvent(type: UInt?, options: UInt, route: UInt?) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
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
        if let artwork, artwork.identity.belongsTo(songID: song.id, url: song.artworkURL) {
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
        resolving?.cancel(); artworkTask?.cancel(); itemObservation?.invalidate(); observations.forEach { $0.invalidate() }
        if let clock { player.removeTimeObserver(clock) }
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        commands.forEach { $0.0.removeTarget($0.1) }
        player.pause(); loader?.invalidate()
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
            let identity = NowPlayingArtworkIdentity(generation: generation, songID: song.id, url: song.artworkURL!)
            artwork = (identity, MPMediaItemArtwork(boundsSize: image.size) { [image] _ in image })
        }
        publishMetadata()
    }
}
#endif
