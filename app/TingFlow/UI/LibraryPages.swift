import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
    @EnvironmentObject private var kugou: KugouStore
    @ObservedObject var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var emby: EmbyStore
    @ObservedObject var netease: NeteaseStore
    @ObservedObject var player: PlayerStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                VStack(spacing: 12) {
                    NavigationLink {
                        NeteaseLibraryView(store: netease, onPlay: { player.play($0, at: $1) })
                    } label: {
                        ConnectionCard(title: "网易云音乐", subtitle: netease.isSignedIn ? netease.accountName : "扫码连接 · 读取自己的歌单", symbol: "music.note")
                    }
                    NavigationLink {
                        EmbyLibraryView(store: emby, onPlay: { player.play($0, at: $1) })
                    } label: {
                        ConnectionCard(title: "Emby 音乐库", subtitle: emby.isSignedIn ? emby.accountName : "歌曲、专辑与播放列表", symbol: "hifispeaker.fill")
                    }
                    NavigationLink {
                        SubsonicLibraryView(store: subsonic, onPlay: { player.play($0, at: $1) })
                    } label: {
                        ConnectionCard(title: "Navidrome / Subsonic", subtitle: subsonic.isSignedIn ? subsonic.accountName : "兼容音乐服 · 专辑与歌单", symbol: "externaldrive.connected.to.line.below")
                    }
                }.buttonStyle(.plain)
                if !netease.playlists.isEmpty {
                    HStack {
                        Text("你的歌单").font(.title2.bold())
                        Spacer()
                        NavigationLink("查看全部") { NeteaseMyPlaylistsView(store: netease, onPlay: { player.play($0, at: $1) }) }
                    }
                    LazyVGrid(columns: typeSize.isAccessibilitySize
                              ? [GridItem(.flexible(), spacing: 16, alignment: .top)]
                              : [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 22) {
                        ForEach(Array(netease.playlists.prefix(4).enumerated()), id: \.offset) { _, playlist in
                            NavigationLink {
                                NeteasePlaylistView(store: netease, playlist: playlist, onPlay: { player.play($0, at: $1) })
                            } label: {
                                NeteasePlaylistCard(playlist: playlist)
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier("playlist-card-\(playlist.id)")
                        }
                    }
                }
                NavigationLink {
                    KugouPlaylistsView(store: kugou, library: library, onPlay: { songs, index in
                        guard let scope = kugou.accountScope,
                              songs.allSatisfy({ $0.accountScope == scope }) else { return }
                        player.play(songs, at: index)
                    })
                } label: {
                    ConnectionCard(title: "酷狗音乐", subtitle: kugou.isSignedIn ? kugou.accountName : "扫码连接 · 云端歌单只读", symbol: "music.note.list")
                }.buttonStyle(.plain).accessibilityIdentifier("browse-kugou-playlists")
            }.padding(20)
        }.navigationTitle("浏览").background(Color(uiColor: .systemBackground))
    }
    private func provider(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.pink).frame(width: 35)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 12)
    }
}

struct MusicLibraryView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
    @EnvironmentObject private var kugou: KugouStore
    @ObservedObject var library: LibraryStore
    @ObservedObject var emby: EmbyStore
    @ObservedObject var netease: NeteaseStore
    @ObservedObject var player: PlayerStore
    @ObservedObject var sources: SourceStore
    @ObservedObject var preferences: PlaybackPreferences
    @State private var showCreate = false
    @State private var name = ""
    var body: some View {
        List {
            if let error = library.persistenceError { Text(error).font(.footnote).foregroundStyle(.red) }
            Section {
                NavigationLink {
                    AccountSettingsView(emby: emby, netease: netease, sources: sources, preferences: preferences)
                } label: { libraryLabel("账号与服务器", symbol: "house") }
                NavigationLink {
                    NeteaseMyPlaylistsView(store: netease, onPlay: { player.play($0, at: $1) })
                } label: { libraryLabel("网易云歌单", symbol: "music.note.list") }
                NavigationLink {
                    NeteaseLibraryView(store: netease, onPlay: { player.play($0, at: $1) })
                } label: { libraryLabel("推荐与私人 FM", symbol: "sparkles") }
                NavigationLink {
                    NeteaseHistoryView(store: netease, onPlay: { player.play($0, at: $1) })
                } label: { libraryLabel("网易云最近播放", symbol: "clock.arrow.circlepath") }
                NavigationLink {
                    KugouPlaylistsView(store: kugou, library: library, onPlay: { songs, index in
                        guard let scope = kugou.accountScope,
                              songs.allSatisfy({ $0.accountScope == scope }) else { return }
                        player.play(songs, at: index)
                    })
                } label: { libraryLabel("酷狗云歌单 · 只读", symbol: "music.note.list") }
                .accessibilityIdentifier("library-kugou-playlists")
            }
            Section("我的收藏") {
                NavigationLink { playlistPage } label: { libraryLabel("播放列表", symbol: "music.note.list") }
                NavigationLink {
                    LocalTrackListView(title: "收藏的歌曲", songs: library.favoriteSongs(), library: library, player: player)
                } label: { libraryLabel("本机收藏歌曲", symbol: "heart") }
                NavigationLink {
                    LocalTrackListView(title: "本机最近播放", songs: library.recentSongs(), library: library, player: player)
                } label: { libraryLabel("本机最近播放", symbol: "clock") }
                NavigationLink {
                    EmbyLibraryView(store: emby, onPlay: { player.play($0, at: $1) })
                } label: { libraryLabel("Emby 歌曲与专辑", symbol: "square.stack") }
                NavigationLink {
                    SubsonicLibraryView(store: subsonic, onPlay: { player.play($0, at: $1) })
                } label: { libraryLabel("Navidrome / Subsonic", symbol: "externaldrive") }
            }
        }.listStyle(.plain).navigationTitle("资料库")
    }
    private func libraryLabel(_ title: String, symbol: String) -> some View {
        Label { Text(title).font(.body.weight(.medium)) } icon: {
            Image(systemName: symbol).font(.title3).foregroundStyle(.pink).frame(width: 30)
        }.frame(minHeight: 34).padding(.vertical, 3)
    }
    private var playlistPage: some View {
        List {
            Button { showCreate = true } label: { Label("新建本地歌单", systemImage: "plus") }
            ForEach(library.playlists) { playlist in
                NavigationLink {
                    LocalTrackListView(title: playlist.name, songs: playlist.songIDs.compactMap { library.visibleSong($0) }, library: library, player: player)
                } label: { Label("\(playlist.name) · \(playlist.songIDs.count) 首", systemImage: "music.note.list") }
            }
        }.navigationTitle("播放列表")
            .alert("新建本地歌单", isPresented: $showCreate) {
                TextField("歌单名称", text: $name)
                Button("创建") { library.createPlaylist(name); name = "" }
                Button("取消", role: .cancel) { name = "" }
            }
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
    @EnvironmentObject private var kugou: KugouStore
    @ObservedObject var emby: EmbyStore
    @ObservedObject var netease: NeteaseStore
    @ObservedObject var sources: SourceStore
    @ObservedObject var preferences: PlaybackPreferences
    var body: some View {
        List {
            Section("音乐账号") {
                NavigationLink { KugouAccountView(store: kugou) } label: {
                    Label(kugou.isSignedIn ? kugou.accountName : "连接酷狗音乐 · 扫码只读", systemImage: "person.crop.circle")
                }.accessibilityIdentifier("settings-kugou-account")
                NavigationLink { NeteaseAccountView(store: netease) } label: {
                    Label(netease.isSignedIn ? "网易云 · \(netease.accountName)" : "连接网易云音乐", systemImage: "person.crop.circle")
                }
                NavigationLink { NeteaseHistoryView(store: netease) } label: {
                    Label("网易云播放记录互通", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { NeteasePlaybackDiagnosticView(store: netease) } label: {
                    Label("网易云播放诊断", systemImage: "waveform.path.ecg")
                }
            }
            Section("自己的服务器") {
                NavigationLink { EmbyAccountView(store: emby) } label: {
                    Label(emby.isSignedIn ? "Emby · \(emby.accountName)" : "添加 Emby 音乐服务器", systemImage: "hifispeaker")
                }
                NavigationLink { SubsonicAccountView(store: subsonic, navidrome: true) } label: {
                    Label("Navidrome", systemImage: "externaldrive")
                }
                NavigationLink { SubsonicAccountView(store: subsonic, navidrome: false) } label: {
                    Label("Subsonic 兼容服务器", systemImage: "server.rack")
                }
                Text("Navidrome 使用 Subsonic 兼容协议。在对应服务中保存并切换服务器，各连接的凭据独立保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义音源") {
                Text("当前播放解析选择：\(sources.selectionLabel)。平台账号与音源权限相互独立；脚本仍需审阅并授权精确域名。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { SourceSelectionView(store: sources) } label: {
                    Label("选择自动或单一播放音源", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                NavigationLink { SourceManagerView(store: sources) } label: {
                    Label("管理洛雪 JS 音源 · \(sources.sources.count)", systemImage: "doc.badge.gearshape")
                }
            }
            Section("播放体验") {
                NavigationLink { PlaybackSettingsView(preferences: preferences).environmentObject(netease) } label: { Label("音质与界面", systemImage: "waveform") }
                NavigationLink { SourceSelectionView(store: sources) } label: {
                    Label("播放解析音源 · \(sources.selectionLabel)", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
            }
            Section("关于") {
                Text("听流 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                NavigationLink { UpdateView() } label: { Label("检查更新", systemImage: "arrow.down.circle") }
                Text("iOS 26 使用系统 TabView、搜索 Tab 与底部播放器附件。网易云为非官方兼容接口，存在失效风险；Emby 仅访问你填写的服务器。构建通过不代表真机登录或播放已验证。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("账号与设置")
    }
}

private struct SearchPlatformFilter: Identifiable {
    let title: String
    let platform: MusicPlatform?
    var id: String { title }
}

struct UnifiedSearchView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
    @ObservedObject var search: SearchStore
    @ObservedObject var library: LibraryStore
    @ObservedObject var emby: EmbyStore
    @ObservedObject var player: PlayerStore
    @ObservedObject var sources: SourceStore
    @State private var source = "全部"
    private var filters: [SearchPlatformFilter] {
        [SearchPlatformFilter(title: "全部", platform: nil), SearchPlatformFilter(title: "网易云", platform: .netease),
         SearchPlatformFilter(title: "酷狗", platform: .kugou)] +
        (emby.isSignedIn ? [SearchPlatformFilter(title: "Emby", platform: .emby)] : []) +
        (subsonic.isSignedIn ? [SearchPlatformFilter(title: "音乐服", platform: .subsonic)] : [])
    }
    private var platforms: [MusicPlatform] { filters.compactMap { $0.platform } }
    private var selectedPlatform: MusicPlatform? { filters.first(where: { $0.title == source })?.platform }
    private var matchesSubmittedQuery: Bool { SearchAggregationPolicy.matches(search.query, submitted: search.submittedQuery) }
    private var visibleResults: [Song] {
        guard matchesSubmittedQuery else { return [] }
        guard let platform = selectedPlatform else { return search.results }
        return search.results.filter { $0.platform == platform }
    }
    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filters) { filter in
                            Button { source = filter.title } label: {
                                Text(filter.title).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(source == filter.title ? Color.white : Color.primary)
                                    .padding(.horizontal, 15).padding(.vertical, 9).frame(minHeight: 44)
                                    .background(source == filter.title ? Color.pink : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("search-filter-\(filter.title)")
                                .accessibilityAddTraits(source == filter.title ? .isSelected : [])
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("搜索结果").font(.headline)
                        Text("按平台聚合 · 点一首即可播放").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    NavigationLink {
                        SourceSelectionView(store: sources) { if let song = player.current { player.play(player.queue, at: player.index) } }
                    } label: {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("播放音源").font(.caption2).foregroundStyle(.secondary)
                            Text(sources.selectionLabel).font(.caption.weight(.semibold)).lineLimit(1)
                        }.foregroundStyle(.primary)
                    }.accessibilityIdentifier("search-parser-selection")
                }
                .listRowSeparator(.hidden)
            }
            if search.isSearching {
                HStack(spacing: 10) { ProgressView(); Text("正在搜索已连接的平台…").font(.footnote).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("search-loading")
            }
            ForEach(platforms, id: \.self) { platform in
                if (selectedPlatform == nil || selectedPlatform == platform), let error = search.failures[platform] {
                    Text("\(platform.title)：\(error)").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("search-error-\(platform.rawValue)")
                }
            }
            if !search.query.isEmpty && !matchesSubmittedQuery && !search.isSearching {
                Text("输入完成后按搜索键；结果会按已连接平台聚合。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if visibleResults.isEmpty && !search.isSearching {
                Text(search.submittedQuery.isEmpty ? "搜索歌曲、歌手或专辑" : "没有找到匹配结果。尝试切换平台或检查连接。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, song in
                    TrackRowView(song: song, play: { player.play(visibleResults, at: index) }, library: library,
                                 artworkSize: 58, showsActions: false)
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                        .accessibilityIdentifier("search-row-\(song.platform.rawValue)-\(song.platformID)")
                }
            }
        }
        .listStyle(.plain).navigationTitle("搜索")
        .searchable(text: $search.query, prompt: "音乐、歌手或专辑")
        .onSubmit(of: .search, run)
        .onChange(of: source) { _ in if !search.query.isEmpty { run() } }
        .onChange(of: search.query) { value in
            if value.isEmpty { search.clear() }
            else if !SearchAggregationPolicy.matches(value, submitted: search.submittedQuery) { search.clear() }
        }
        .onChange(of: emby.isSignedIn) { _ in normalizeFilter() }
        .onChange(of: subsonic.isSignedIn) { _ in normalizeFilter() }
        .task { normalizeFilter() }
    }
    private func normalizeFilter() { if !filters.contains(where: { $0.title == source }) { source = "全部" } }
    private func run() {
        let selected = filters.first(where: { $0.title == source })?.platform.map { [$0] } ?? platforms
        search.search(platforms: selected)
    }
}
