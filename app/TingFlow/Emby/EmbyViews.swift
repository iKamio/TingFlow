import SwiftUI

struct EmbyAccountView: View {
    @ObservedObject var store: EmbyStore
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var addingServer = false
    var body: some View {
        Form {
            if !store.connections.isEmpty {
                Section("我的音乐服") {
                    ForEach(store.connections) { connection in
                        Button { Task { await store.selectConnection(id: connection.id) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.title).foregroundStyle(.primary)
                                    Text(connection.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.activeConnectionID == connection.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                }
                            }
                        }.disabled(store.isLoading)
                        .swipeActions {
                            Button("移除", role: .destructive) { Task { await store.removeConnection(id: connection.id) } }
                        }
                    }
                }
            }
            if store.isSignedIn {
                Section("Emby 账户") {
                    Text(store.accountName)
                    Button("刷新音乐库首批数据") { Task { await store.refresh() } }.disabled(store.isLoading)
                    Button("移除此音乐服", role: .destructive) { Task { await store.signOut() } }
                    ForEach(EmbyLibraryKind.allCases) { kind in
                        Text("\(kind.title)：\(store.pageState(kind).progressText)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                DisclosureGroup("添加 Emby 音乐服", isExpanded: Binding(get: { addingServer || store.connections.isEmpty }, set: { addingServer = $0 })) {
                    TextField("https://host/emby", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码（允许为空）", text: $password).textContentType(.password)
                    Button("连接并保存") {
                        let secret = password; password = ""
                        Task { await store.signIn(baseURL: baseURL, username: username, password: secret) }
                    }.disabled(store.isLoading || baseURL.isEmpty || username.isEmpty)
                }
            }
            Section {
                Text("可保存并切换多个 Emby 音乐服。使用最终 HTTPS 地址，密码不保存，访问令牌仅保存在本机钥匙串。音乐库按需读取，不会后台持续扫描。")
                    .font(.footnote).foregroundStyle(.secondary)
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
        .navigationTitle("Emby 音乐服")
        .onDisappear { password = "" }
    }
}

@MainActor struct EmbyLibraryView: View {
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
                if store.connections.count > 1 {
                    Menu {
                        ForEach(store.connections) { connection in
                            Button { Task { await store.selectConnection(id: connection.id) } } label: {
                                Label(connection.title + " · " + connection.subtitle,
                                      systemImage: store.activeConnectionID == connection.id ? "checkmark" : "server.rack")
                            }
                        }
                    } label: { Label("切换音乐服", systemImage: "arrow.triangle.swap") }
                        .disabled(store.isLoading)
                }
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
        .task(id: store.scopeID) {
            if store.isSignedIn { await store.refreshIfNeeded() }
        }
    }
    private func category(_ kind: EmbyLibraryKind) -> some View {
        ScrollView {
            LazyVGrid(columns: kind == .songs ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 145), spacing: 16)], alignment: .leading, spacing: kind == .songs ? 14 : 22) {
            if store.isSignedIn {
                if kind == .songs {
                    ForEach(Array(store.songs.enumerated()), id: \.offset) { index, song in
                        Button { onPlay(store.songs, index) } label: { EmbySongRow(song: song) }.buttonStyle(.plain)
                    }
                } else if kind == .albums {
                    ForEach(store.albums) { album in
                        let collection = ServerCollectionInfo(service: "emby", kind: .album, id: album.id,
                                                              title: album.name, artist: album.artist,
                                                              songCount: album.songCount, accountScope: album.accountScope,
                                                              artworkVersion: album.primaryImageTag)
                        NavigationLink {
                            EmbyCollectionView(store: store, collection: collection, onPlay: onPlay,
                                               artwork: { pixels in try await store.artwork(for: album, pixels: pixels) }) { cursor in
                                try await store.tracks(in: album, cursor: cursor)
                            }
                        } label: {
                            ServerCollectionTile(collection: collection, scope: store.isSignedIn ? store.scopeID : nil) { pixels in
                                try await store.artwork(for: album, pixels: pixels)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(collection.accessibilityID + ".row")
                    }
                } else {
                    ForEach(store.playlists) { playlist in
                        let collection = ServerCollectionInfo(service: "emby", kind: .playlist, id: playlist.id,
                                                              title: playlist.name, artist: playlist.artist,
                                                              songCount: playlist.songCount, accountScope: playlist.accountScope,
                                                              artworkVersion: playlist.primaryImageTag)
                        NavigationLink {
                            EmbyCollectionView(store: store, collection: collection, onPlay: onPlay,
                                               artwork: { pixels in try await store.artwork(for: playlist, pixels: pixels) }) { cursor in
                                try await store.tracks(in: playlist, cursor: cursor)
                            }
                        } label: {
                            ServerCollectionTile(collection: collection, scope: store.isSignedIn ? store.scopeID : nil) { pixels in
                                try await store.artwork(for: playlist, pixels: pixels)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(collection.accessibilityID + ".row")
                    }
                }
                pagingRow(kind)
            } else { Text("请先连接 Emby。").foregroundStyle(.secondary) }
            }.padding(20)
        }.navigationTitle(kind.title).background(Color(uiColor: .systemBackground)).refreshable { await store.refresh() }
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
        HStack(spacing: 12) {
            ArtworkView(url: song.displayArtworkURL, corner: 7).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).foregroundStyle(.primary).lineLimit(1)
                Text(song.artist.isEmpty ? song.album : song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

@MainActor private struct EmbyCollectionView: View {
    @ObservedObject var store: EmbyStore
    let collection: ServerCollectionInfo
    let onPlay: ([Song], Int) -> Void
    let artwork: @MainActor (Int) async throws -> Data?
    let load: (EmbyCursor) async throws -> EmbyTrackBatch
    @State private var tracks: [Song] = []
    @State private var cursor = EmbyCursor()
    @State private var loaded = false
    @State private var retryFromStart = false
    @State private var loading = false
    @State private var error: String?
    @State private var ticket = UUID()
    private var isCurrent: Bool { store.isSignedIn && store.scopeID == collection.accountScope }
    private var visible: [Song] { isCurrent ? tracks.filter { $0.accountScope == store.scopeID } : [] }
    var body: some View {
        List {
            Section {
                ServerCollectionHeader(collection: collection, scope: store.isSignedIn ? store.scopeID : nil, load: artwork)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            Section {
                if !isCurrent {
                    Text("账号已变化，请返回音乐库。").foregroundStyle(.secondary)
                } else if loaded {
                    Text("已读取 \(cursor.nextIndex)" + (cursor.total.map { " / \($0)" } ?? "") + " 条 · 队列仅含已加载音频")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !visible.isEmpty {
                    Button { onPlay(visible, 0) } label: {
                        Label("播放已加载曲目", systemImage: "play.fill").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier(collection.accessibilityID + ".playLoaded")
                }
            }
            if isCurrent, let error { Text(error).foregroundStyle(.red) }
            // Use queue position: a song may repeat in a playlist.
            ForEach(Array(visible.enumerated()), id: \.offset) { index, song in
                Button { onPlay(visible, index) } label: { EmbySongRow(song: song) }
            }
            if isCurrent && loading { ProgressView("读取歌曲…") }
            else if isCurrent, !loaded || cursor.hasMore || error != nil {
                Button(error == nil ? "加载更多曲目" : "重试加载曲目") { Task { await fetch(reset: false) } }
            } else if isCurrent && loaded && visible.isEmpty { Text("暂无音频曲目").foregroundStyle(.secondary) }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.scopeID) {
            tracks = []; cursor = EmbyCursor(); loaded = false; loading = false; error = nil; retryFromStart = false
            await fetch(reset: true)
        }
        .refreshable { await fetch(reset: true) }
        .onChange(of: store.scopeID) { _ in
            ticket = UUID(); tracks = []; cursor = EmbyCursor(); loaded = false; loading = false
            error = nil; retryFromStart = false
        }
    }
    private func fetch(reset: Bool) async {
        guard isCurrent, let scope = store.scopeID, reset || !loading else { return }
        let shouldReset = reset || retryFromStart
        let id = UUID(); ticket = id; loading = true; error = nil
        defer { if ticket == id { loading = false } }
        do {
            let result = try await load(shouldReset ? EmbyCursor() : cursor)
            try Task.checkCancellation()
            guard ticket == id, isCurrent, store.scopeID == scope, result.accountScope == scope else { return }
            tracks = (shouldReset ? [] : tracks) + result.songs
            cursor = result.cursor; loaded = true; retryFromStart = false
        } catch is CancellationError { }
        catch {
            guard ticket == id, !Task.isCancelled, isCurrent, store.scopeID == scope else { return }
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
