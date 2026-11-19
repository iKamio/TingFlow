import SwiftUI

/// Native tab bar, never a custom overlay: iOS 26 supplies Liquid Glass.
struct ContentView: View {
    @StateObject private var library = LibraryStore()
    @StateObject private var search = SearchStore()
    @StateObject private var emby = EmbyStore()
    @StateObject private var netease = NeteaseStore()
    @StateObject private var subsonic = SubsonicStore()
    @StateObject private var sources = SourceStore()
    @StateObject private var player = PlayerStore()
    @StateObject private var preferences = PlaybackPreferences()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var playerTransition
    @State private var tab = 0
    @State private var showPlayer = false
    @State private var showAccounts = false
    @State private var embyScope: String?
    @State private var neteaseScope: String?
    @State private var subsonicScope: String?
    @State private var playbackNotice: String?

    var body: some View {
        tabs
            .environmentObject(preferences)
            .environmentObject(netease)
            .environmentObject(subsonic)
            .tint(Color(red: 0.98, green: 0.18, blue: 0.33))
            .fullScreenCover(isPresented: $showPlayer) {
                NowPlayingView(player: player, library: library, netease: netease)
                    .environmentObject(preferences)
                    .modifier(PlayerSheetTransition(namespace: playerTransition, enabled: !reduceMotion))
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showAccounts) {
                NavigationStack {
                    AccountSettingsView(emby: emby, netease: netease, sources: sources, preferences: preferences)
                        .environmentObject(subsonic)
                        .environmentObject(preferences)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showAccounts = false } } }
                }
            }
            .task {
                #if DEBUG
                if UIPolishFixture.enabled {
                    netease.seedPolishFixture(); player.seedPolishFixture()
                    library.activateScopes([UIPolishFixture.scope])
                    return
                }
                #endif
                embyScope = emby.scopeID; neteaseScope = netease.scopeID; subsonicScope = subsonic.scopeID
                library.activateScopes(Set([emby.scopeID, netease.scopeID, subsonic.scopeID].compactMap { $0 }))
                player.resolver = { [weak emby, weak netease, weak subsonic, weak sources, weak preferences] song in
                    let quality = preferences?.quality ?? .high
                    let useSources = preferences?.useSources ?? true
                    switch song.platform {
                    case .emby:
                        guard let emby else { throw MusicError.unsupported("请连接 Emby。") }
                        return try await emby.playback(for: song)
                    case .subsonic:
                        guard let subsonic else { throw MusicError.unsupported("请连接音乐服务器。") }
                        return try await subsonic.playback(for: song)
                    case .netease:
                        guard let netease else { throw MusicError.unsupported("请连接网易云。") }
                        do {
                            let resource = try await netease.playback(for: song, quality: quality, mode: preferences?.playbackMode ?? .nativeV1)
                            if resource.isPreview, useSources, let sources, sources.hasEnabledSources {
                                do { return try await sources.resolveWithMatching(for: song, quality: quality) }
                                catch { try Task.checkCancellation(); return resource }
                            }
                            return resource
                        }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            guard NeteasePlaybackSafety.allowsSourceFallback(after: error), useSources,
                                  let sources, sources.hasEnabledSources else { throw error }
                            return try await sources.resolveWithMatching(for: song, quality: quality)
                        }
                    case .kugou:
                        guard useSources, let sources, sources.hasEnabledSources else { throw MusicError.unsupported("请在账号与设置导入并启用支持酷狗的音源。无需把网易云账号交给音源。") }
                        return try await sources.playback(for: song, quality: quality)
                    case .local:
                        throw MusicError.unsupported("本地音频导入尚未接入。")
                    }
                }
                player.onStarted = { [weak library] song in library?.recordPlayed(song) }
                player.reportsListening = netease.syncPlaybackHistory
                player.onListeningStarted = { [weak netease] session in netease?.enqueueListeningStart(session) }
                player.onListeningFinished = { [weak netease] snapshot, natural in netease?.enqueueListeningFinish(snapshot, naturalEnd: natural) }
                search.embySearch = { [weak emby] text in
                    guard let emby else { return [] }
                    return try await emby.search(text)
                }
                search.subsonicSearch = { [weak subsonic] text in
                    guard let subsonic else { return [] }
                    return try await subsonic.search(text)
                }
                await netease.refresh()
            }
            .onChange(of: netease.syncPlaybackHistory) { value in player.reportsListening = value }
            .onChange(of: player.errorMessage) { value in playbackNotice = value }
            .alert("无法播放", isPresented: Binding(get: { playbackNotice != nil }, set: { if !$0 { playbackNotice = nil } })) {
                Button("知道了", role: .cancel) { playbackNotice = nil }
            } message: { Text(playbackNotice ?? "") }
            .onChange(of: emby.scopeID) { value in
                clearScope(embyScope, new: value, platform: .emby); embyScope = value
            }
            .onChange(of: netease.scopeID) { value in
                clearScope(neteaseScope, new: value, platform: .netease); neteaseScope = value
            }
            .onChange(of: subsonic.scopeID) { value in
                clearScope(subsonicScope, new: value, platform: .subsonic); subsonicScope = value
            }
    }

    @ViewBuilder private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $tab) {
                Tab("现在就听", systemImage: "play.circle.fill", value: 0) { page(0) }
                Tab("浏览", systemImage: "square.grid.2x2.fill", value: 1) { page(1) }
                Tab("资料库", systemImage: "music.note.list", value: 2) { page(2) }
                Tab(value: 3, role: .search) { page(3) }
            }
            // System inline/expanded accessory placement follows the user's reference video.
            .tabBarMinimizeBehavior(preferences.minimizeTabBar ? .onScrollDown : .never)
            .tabViewBottomAccessory {
                MiniPlayerView(player: player) { if player.current != nil { showPlayer = true } }
                    .modifier(PlayerTransitionSource(namespace: playerTransition, enabled: !reduceMotion))
            }
        } else {
            TabView(selection: $tab) {
                page(0).tabItem { Label("现在就听", systemImage: "play.circle.fill") }.tag(0)
                page(1).tabItem { Label("浏览", systemImage: "square.grid.2x2.fill") }.tag(1)
                page(2).tabItem { Label("资料库", systemImage: "music.note.list") }.tag(2)
                page(3).tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(3)
            }
        }
    }
    private func page(_ index: Int) -> some View {
        NavigationStack {
            Group {
                switch index {
                case 1: BrowseView(emby: emby, netease: netease, player: player)
                case 2: MusicLibraryView(library: library, emby: emby, netease: netease, player: player, sources: sources, preferences: preferences)
                case 3: UnifiedSearchView(search: search, library: library, emby: emby, player: player)
                default: ListenNowView(library: library, emby: emby, netease: netease, player: player, connect: { showAccounts = true })
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAccounts = true } label: {
                        AccountAvatarView(url: netease.isSignedIn ? netease.avatarURL : nil)
                    }
                        .accessibilityLabel("账号与服务器设置")
                }
            }
            .modifier(LegacyMiniPlayer(player: player, showPlayer: $showPlayer))
        }
    }
    private func clearScope(_ old: String?, new: String?, platform: MusicPlatform) {
        library.activateScopes(Set([emby.scopeID, netease.scopeID, subsonic.scopeID].compactMap { $0 }))
        guard let old, old != new else { return }
        if player.queue.contains(where: { $0.platform == platform }) { player.stop() }
        library.removeAccountScope(old)
        search.clear()
    }
}

private struct LegacyMiniPlayer: ViewModifier {
    @ObservedObject var player: PlayerStore
    @Binding var showPlayer: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content }
        else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerView(player: player) { if player.current != nil { showPlayer = true } }
                    .padding(.horizontal, 8).background(.regularMaterial)
            }
        }
    }
}
