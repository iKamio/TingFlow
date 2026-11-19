import SwiftUI

struct EmbyAccountView: View {
    @ObservedObject var store: EmbyStore
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    var body: some View {
        Form {
            if store.isSignedIn {
                Section("Emby 账户") {
                    Text(store.accountName)
                    Button("刷新音乐库首批数据") { Task { await store.refresh() } }.disabled(store.isLoading)
                    Button("退出登录", role: .destructive) { Task { await store.signOut() } }
                    ForEach(EmbyLibraryKind.allCases) { kind in
                        Text("\(kind.title)：\(store.pageState(kind).progressText)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("连接 Emby") {
                    TextField("https://host/emby", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码（允许为空）", text: $password).textContentType(.password)
                    Button("登录") {
                        let secret = password; password = ""
                        Task { await store.signIn(baseURL: baseURL, username: username, password: secret) }
                    }.disabled(store.isLoading || baseURL.isEmpty || username.isEmpty)
                }
                Section {
                    Text("使用服务器最终 HTTPS API 根地址，保留反向代理子路径。密码不保存；访问令牌仅保存在本机钥匙串。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if store.isLoading { ProgressView("正在连接…") }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if store.isSignedIn {
                Section("排查播放问题") {
                    NavigationLink("查看脱敏播放诊断") { EmbyPlaybackDiagnosticView(store: store) }
                    Text("点播失败后查看脱敏协议、格式和能力标志。当前仅验证原始音频渐进式直放，尚不支持转码或直播会话。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Emby 账户")
        .onDisappear { password = "" }
    }
}

struct EmbyLibraryView: View {
    @ObservedObject var store: EmbyStore
    let onPlay: ([Song], Int) -> Void
    init(store: EmbyStore, onPlay: @escaping ([Song], Int) -> Void) {
        self.store = store; self.onPlay = onPlay
    }
    var body: some View {
        List {
            Section {
                NavigationLink { EmbyAccountView(store: store) } label: {
                    Label(store.isSignedIn ? store.accountName : "连接 Emby 服务器", systemImage: "person.crop.circle")
                }
                Text("只读音乐库 · 每次读取最多 100 条，不要求一次加载完整库。播放队列包含你点播时已加载的曲目。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if store.isLoading { ProgressView("加载音乐库…") }
            Section("音乐分类") {
                NavigationLink { category(.playlists) } label: { Label("歌单", systemImage: "music.note.list").frame(minHeight: 44) }
                NavigationLink { category(.albums) } label: { Label("专辑", systemImage: "square.stack").frame(minHeight: 44) }
                NavigationLink { category(.songs) } label: { Label("歌曲", systemImage: "music.note").frame(minHeight: 44) }
            }
        }
        .navigationTitle("Emby 音乐库")
        .refreshable { await store.refresh() }
        .task {
            if store.isSignedIn, !store.isLoading, !store.pageState(.songs).isLoaded { await store.refresh() }
        }
    }
    private func category(_ kind: EmbyLibraryKind) -> some View {
        List {
            if store.isSignedIn {
                if kind == .songs {
                    ForEach(Array(store.songs.enumerated()), id: \.offset) { index, song in
                        Button { onPlay(store.songs, index) } label: { EmbySongRow(song: song) }.buttonStyle(.plain)
                    }
                } else if kind == .albums {
                    ForEach(store.albums) { album in
                        NavigationLink(album.name) {
                            EmbyCollectionView(store: store, title: album.name, onPlay: onPlay) { cursor in
                                try await store.tracks(in: album, cursor: cursor)
                            }
                        }
                    }
                } else {
                    ForEach(store.playlists) { playlist in
                        NavigationLink(playlist.name) {
                            EmbyCollectionView(store: store, title: playlist.name, onPlay: onPlay) { cursor in
                                try await store.tracks(in: playlist, cursor: cursor)
                            }
                        }
                    }
                }
                pagingRow(kind)
            } else { Text("请先连接 Emby。").foregroundStyle(.secondary) }
        }.listStyle(.plain).navigationTitle(kind.title).refreshable { await store.refresh() }
    }
    @ViewBuilder private func pagingRow(_ kind: EmbyLibraryKind) -> some View {
        if store.isSignedIn {
            let state = store.pageState(kind)
            VStack(alignment: .leading, spacing: 8) {
                Text(state.progressText).font(.caption).foregroundStyle(.secondary)
                if let error = state.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if state.isLoading { ProgressView("读取\(kind.title)…") }
                else if !state.isLoaded || state.cursor.hasMore || state.error != nil {
                    Button(state.error == nil ? "加载更多\(kind.title)" : "重试读取\(kind.title)") {
                        Task { await store.loadMore(kind) }
                    }.disabled(store.isLoading)
                }
            }.padding(.vertical, 7)
        }
    }
}

private struct EmbySongRow: View {
    let song: Song
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(song.title).foregroundStyle(.primary)
            Text(song.artist.isEmpty ? song.album : song.artist).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct EmbyCollectionView: View {
    @ObservedObject var store: EmbyStore
    let title: String
    let onPlay: ([Song], Int) -> Void
    let load: (EmbyCursor) async throws -> EmbyTrackBatch
    @State private var tracks: [Song] = []
    @State private var cursor = EmbyCursor()
    @State private var loaded = false
    @State private var retryFromStart = false
    @State private var loading = false
    @State private var error: String?
    @State private var ticket = UUID()
    private var visible: [Song] { tracks.filter { $0.accountScope == store.scopeID } }
    var body: some View {
        List {
            Section {
                if loaded {
                    Text("已读取 \(cursor.nextIndex)" + (cursor.total.map { " / \($0)" } ?? "") + " 条 · 队列仅含已加载音频")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !visible.isEmpty {
                    Button { onPlay(visible, 0) } label: { Label("播放已加载曲目", systemImage: "play.fill") }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            // Use queue position: a song may repeat in a playlist.
            ForEach(Array(visible.enumerated()), id: \.offset) { index, song in
                Button { onPlay(visible, index) } label: { EmbySongRow(song: song) }
            }
            if loading { ProgressView("读取歌曲…") }
            else if store.isSignedIn, !loaded || cursor.hasMore || error != nil {
                Button(error == nil ? "加载更多曲目" : "重试加载曲目") { Task { await fetch(reset: false) } }
            } else if loaded && visible.isEmpty { Text("暂无音频曲目").foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .task(id: store.scopeID) {
            tracks = []; cursor = EmbyCursor(); loaded = false; loading = false
            await fetch(reset: true)
        }
        .refreshable { await fetch(reset: true) }
        .onChange(of: store.scopeID) { _ in ticket = UUID(); tracks = []; loaded = false; loading = false }
    }
    private func fetch(reset: Bool) async {
        guard let scope = store.scopeID, reset || !loading else { return }
        let shouldReset = reset || retryFromStart
        let id = UUID(); ticket = id; loading = true; error = nil
        defer { if ticket == id { loading = false } }
        do {
            let result = try await load(shouldReset ? EmbyCursor() : cursor)
            try Task.checkCancellation()
            guard ticket == id, store.scopeID == scope, result.accountScope == scope else { return }
            tracks = (shouldReset ? [] : tracks) + result.songs
            cursor = result.cursor; loaded = true; retryFromStart = false
        } catch is CancellationError { }
        catch {
            guard ticket == id, !Task.isCancelled, store.scopeID == scope else { return }
            self.error = (error as? EmbyFailure ?? .network).localizedDescription
            retryFromStart = shouldReset
        }
    }
}


struct EmbyPlaybackDiagnosticView: View {
    @ObservedObject var store: EmbyStore
    var body: some View {
        ScrollView {
            Text(store.playbackDiagnostic ?? "还没有播放请求。请先从音乐库点播一首歌曲，再返回这里查看。")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("播放诊断")
    }
}
