import SwiftUI

struct SubsonicAccountView: View {
    @ObservedObject var store: SubsonicStore
    let navidrome: Bool
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""

    init(store: SubsonicStore, navidrome: Bool = false) {
        self.store = store; self.navidrome = navidrome
    }
    private var service: String { navidrome ? "Navidrome" : "Subsonic" }
    var body: some View {
        Form {
            if store.isSignedIn {
                Section("\(store.serviceLabel) 账户") {
                    Text(store.accountName)
                    Button("刷新音乐库") { Task { await store.refresh() } }.disabled(store.isLoading)
                    Button("退出登录", role: .destructive) { Task { await store.signOut() } }
                    Text("已验证当前服务器；播放使用标准 Subsonic 原始音频直放。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("连接\(service)") {
                    TextField("https://host/music", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                    Button("登录") {
                        let secret = password; password = ""
                        Task { await store.signIn(baseURL: baseURL, username: username,
                                                  password: secret, navidrome: navidrome) }
                    }.disabled(store.isLoading || baseURL.isEmpty || username.isEmpty)
                }
                Section {
                    Text("仅接受最终 HTTPS 根地址，可保留反向代理子路径。密码不会保存；每次登录生成随机盐，令牌和盐仅保存在本机钥匙串。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if store.isLoading { ProgressView("正在连接…") }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("\(service) 账户")
        .onDisappear { password = "" }
    }
}

struct SubsonicLibraryView: View {
    @ObservedObject var store: SubsonicStore
    let onPlay: ([Song], Int) -> Void
    @State private var query = ""
    @State private var searchResults: [Song] = []
    @State private var searchError: String?
    @State private var searching = false
    @State private var searchID = UUID()
    @State private var searchTask: Task<Void, Never>?

    init(store: SubsonicStore, onPlay: @escaping ([Song], Int) -> Void) {
        self.store = store; self.onPlay = onPlay
    }
    var body: some View {
        List {
            Section {
                NavigationLink { SubsonicAccountView(store: store) } label: {
                    Label(store.isSignedIn ? store.accountName : "连接 Navidrome / Subsonic 服务器",
                          systemImage: "person.crop.circle")
                }
                if !store.isSignedIn {
                    Text("尚未连接服务器；登录成功并通过 ping 验证后才会显示音乐库。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("只读取专辑、歌单及点开的曲目；专辑分页每次最多 100 条，搜索最多 100 首。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if searching { ProgressView("搜索中…") }
            if let searchError { Text(searchError).foregroundStyle(.red) }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("搜索结果（最多 100 首）") {
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { index, song in
                        Button { onPlay(searchResults, index) } label: { SubsonicSongRow(song: song) }
                    }
                    if !searching && searchResults.isEmpty { Text("没有找到音频").foregroundStyle(.secondary) }
                }
            }
            if store.isSignedIn {
                Section("音乐分类") {
                    NavigationLink { albumPage } label: { Label("专辑", systemImage: "square.stack").frame(minHeight: 44) }
                    NavigationLink { playlistPage } label: { Label("歌单", systemImage: "music.note.list").frame(minHeight: 44) }
                }
            }
        }
        .navigationTitle("\(store.serviceLabel) 音乐库")
        .searchable(text: $query, prompt: "搜索歌曲、专辑或艺术家")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: store.scopeID) { _ in clearSearch() }
        .onChange(of: query) { _ in clearSearch() }
        .onDisappear { clearSearch() }
        .refreshable { await store.refresh() }
        .task(id: store.scopeID) {
            if store.isSignedIn && store.albums.isEmpty && !store.isLoading { await store.refresh() }
        }
    }
    private var albumPage: some View {
        List {
            if store.isSignedIn {
                ForEach(store.albums) { album in
                    NavigationLink(album.name) {
                        SubsonicCollectionView(store: store, scope: album.accountScope, title: album.name, onPlay: onPlay) {
                            try await store.tracks(in: album)
                        }
                    }
                }
                if store.albums.count >= SubsonicPolicy.pageSize {
                    Button("加载更多专辑") { Task { await store.loadMoreAlbums() } }.disabled(store.isLoading)
                }
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } else { Text("账号已退出").foregroundStyle(.secondary) }
        }.navigationTitle("专辑").listStyle(.plain)
    }
    private var playlistPage: some View {
        List {
            if store.isSignedIn {
                ForEach(store.playlists) { playlist in
                    NavigationLink(playlist.name) {
                        SubsonicCollectionView(store: store, scope: playlist.accountScope, title: playlist.name, onPlay: onPlay) {
                            try await store.tracks(in: playlist)
                        }
                    }
                }
                if store.playlists.isEmpty { Text("暂无歌单").foregroundStyle(.secondary) }
            } else { Text("账号已退出").foregroundStyle(.secondary) }
        }.navigationTitle("歌单").listStyle(.plain)
    }
    private func clearSearch() {
        searchID = UUID(); searchTask?.cancel(); searchTask = nil
        searchResults = []; searching = false; searchError = nil
    }
    private func runSearch() {
        clearSearch()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.isSignedIn, let scope = store.scopeID else { return }
        let id = searchID; searching = true
        searchTask = Task {
            defer { if searchID == id { searching = false; searchTask = nil } }
            do {
                let result = try await store.search(text)
                try Task.checkCancellation()
                guard searchID == id, store.scopeID == scope, query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                searchResults = result
            } catch is CancellationError { }
            catch { if searchID == id, store.scopeID == scope { searchError = (error as? SubsonicFailure ?? .network).localizedDescription } }
        }
    }
}

private struct SubsonicSongRow: View {
    let song: Song
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(song.title).foregroundStyle(.primary)
            Text(song.artist.isEmpty ? song.album : song.artist)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SubsonicCollectionView: View {
    @ObservedObject var store: SubsonicStore
    let scope: String
    let title: String
    let onPlay: ([Song], Int) -> Void
    let load: () async throws -> [Song]
    @State private var tracks: [Song] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView("读取歌曲…") }
            if loaded && tracks.isEmpty && !loading { Text("暂无音频曲目").foregroundStyle(.secondary) }
            if store.scopeID == scope, store.isSignedIn {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, song in
                    Button { onPlay(tracks, index) } label: { SubsonicSongRow(song: song) }
                }
                if loaded && !tracks.isEmpty {
                    Button { onPlay(tracks, 0) } label: { Label("播放全部已加载曲目", systemImage: "play.fill") }
                }
            } else { Text("账号已变化，请返回音乐库。").foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .task(id: store.scopeID) { await fetch() }
        .onChange(of: store.scopeID) { _ in tracks = []; loaded = false; loading = false; error = nil }
        .refreshable { await fetch() }
    }
    private func fetch() async {
        guard !loading, store.scopeID == scope, store.isSignedIn else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await load()
            try Task.checkCancellation()
            guard store.scopeID == scope, store.isSignedIn else { return }
            tracks = result; loaded = true
        } catch is CancellationError { }
        catch { if store.scopeID == scope { self.error = (error as? SubsonicFailure ?? .network).localizedDescription } }
    }
}
