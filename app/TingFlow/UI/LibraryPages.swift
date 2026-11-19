import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
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
                VStack(alignment: .leading, spacing: 8) {
                    Label("酷狗已接入搜索", systemImage: "magnifyingglass").font(.headline)
                    Text("酷狗可通过你信任并启用的洛雪 JS 解析播放；账号登录仍待接入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
        }.frame(minHeight: 38).padding(.vertical, 7)
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
    @ObservedObject var emby: EmbyStore
    @ObservedObject var netease: NeteaseStore
    @ObservedObject var sources: SourceStore
    @ObservedObject var preferences: PlaybackPreferences
    var body: some View {
        List {
            Section("音乐账号") {
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
                Text("Navidrome 使用 Subsonic 兼容协议。本版可同时连接 Emby 和一个兼容协议账号；不会混用两种服务的凭据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义音源") {
                NavigationLink { SourceManagerView(store: sources) } label: {
                    Label("管理洛雪 JS 音源 · \(sources.sources.count)", systemImage: "doc.badge.gearshape")
                }
                Text(sources.hasEnabledSources ? "音源由你授权；播放失败时按启用顺序尝试。" : "尚无启用音源。只支持经审查的 LX mobile 2.0 子集，不共享平台 Cookie。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("播放体验") {
                NavigationLink { PlaybackSettingsView(preferences: preferences) } label: { Label("音质与界面", systemImage: "waveform") }
            }
            Section("关于") {
                Text("听流 · 0.5.1")
                NavigationLink { UpdateView() } label: { Label("检查更新", systemImage: "arrow.down.circle") }
                Text("iOS 26 使用系统 TabView、搜索 Tab 与底部播放器附件。网易云为非官方兼容接口，存在失效风险；Emby 仅访问你填写的服务器。构建通过不代表真机登录或播放已验证。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("账号与设置")
    }
}

struct UnifiedSearchView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
    @ObservedObject var search: SearchStore
    @ObservedObject var library: LibraryStore
    @ObservedObject var emby: EmbyStore
    @ObservedObject var player: PlayerStore
    @State private var source = "全部"
    private let options = ["全部", "网易云", "酷狗", "Emby", "音乐服"]
    var body: some View {
        List {
            Section {
                Picker("来源", selection: $source) { ForEach(options, id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).padding(.vertical, 5)
            }
            if search.isSearching { ProgressView("正在搜索…") }
            ForEach([MusicPlatform.netease, .kugou, .emby, .subsonic]) { platform in
                if let error = search.failures[platform] {
                    Text("\(platform.title)：\(error)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !search.isSearching, !search.query.isEmpty, (source == "全部" || source == "Emby"), let notice = emby.searchNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
            if search.results.isEmpty && !search.isSearching {
                Text(source == "Emby" && !emby.isSignedIn ? "请先在账号设置连接 Emby 服务器。" : "搜索歌曲、歌手或专辑关键词")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(search.results.enumerated()), id: \.offset) { index, song in
                TrackRowView(song: song, play: { player.play(search.results, at: index) }, library: library)
            }
        }
        .listStyle(.plain).navigationTitle("搜索")
        .searchable(text: $search.query, prompt: "音乐、歌手或专辑")
        .onSubmit(of: .search, run)
        .onChange(of: source) { _ in if !search.query.isEmpty { run() } }
        .onChange(of: search.query) { if $0.isEmpty { search.clear() } }
    }
    private func run() {
        let platforms: [MusicPlatform]
        switch source {
        case "网易云": platforms = [.netease]
        case "酷狗": platforms = [.kugou]
        case "Emby": platforms = [.emby]
        case "音乐服": platforms = [.subsonic]
        default:
            platforms = [.netease, .kugou] + (emby.isSignedIn ? [.emby] : []) + (subsonic.isSignedIn ? [.subsonic] : [])
        }
        search.search(platforms: platforms)
    }
}
