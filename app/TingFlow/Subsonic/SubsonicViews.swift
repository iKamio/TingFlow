import SwiftUI

struct SubsonicAccountView: View {
    @ObservedObject var store: SubsonicStore
    let navidrome: Bool
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var addingServer = false
    @State private var useNavidrome: Bool

    init(store: SubsonicStore, navidrome: Bool = false) {
        self.store = store; self.navidrome = navidrome
        _useNavidrome = State(initialValue: navidrome)
    }
    private var service: String { navidrome ? "Navidrome" : "Subsonic" }
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
                Section("\(store.serviceLabel) 账户") {
                    Text(store.accountName)
                    Button("刷新音乐库") { Task { await store.refresh() } }.disabled(store.isLoading)
                    Button("移除此音乐服", role: .destructive) { Task { await store.signOut() } }
                }
            }
            Section {
                DisclosureGroup("添加音乐服", isExpanded: Binding(get: { addingServer || store.connections.isEmpty }, set: { addingServer = $0 })) {
                    Toggle("Navidrome", isOn: $useNavidrome)
                    TextField("https://host/music", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                    Button("连接并保存") {
                        let secret = password; password = ""
                        Task { await store.signIn(baseURL: baseURL, username: username,
                                                  password: secret, navidrome: useNavidrome) }
                    }.disabled(store.isLoading || baseURL.isEmpty || username.isEmpty)
                }
            }
            Section {
                Text("连接保存在本机，可随时切换。仅使用 HTTPS；令牌和随机盐保存在钥匙串，密码不保存。音乐库按需读取并缓存，不会后台持续扫描。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.isLoading { ProgressView("正在连接…") }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("音乐服管理")
        .onDisappear { password = "" }
    }
}

@MainActor struct SubsonicLibraryView: View {
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
                }
                if store.connections.count > 1 { connectionMenu }
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
            if store.isSignedIn { await store.refreshIfNeeded() }
        }
    }
    private var albumPage: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], alignment: .leading, spacing: 22) {
            if store.isSignedIn {
                ForEach(store.albums) { album in
                    let collection = ServerCollectionInfo(service: "subsonic", kind: .album, id: album.id,
                                                          title: album.name, artist: album.artist,
                                                          songCount: album.songCount, accountScope: album.accountScope,
                                                          artworkVersion: album.coverArtID)
                    NavigationLink {
                        SubsonicCollectionView(store: store, collection: collection, onPlay: onPlay,
                                               artwork: { pixels in try await store.artwork(for: album, pixels: pixels) },
                                               diagnosticArtwork: { pixels in try await store.artworkResult(for: album, pixels: pixels) }) {
                            try await store.tracks(in: album)
                        }
                    } label: {
                        ServerCollectionTile(collection: collection, scope: store.isSignedIn ? store.scopeID : nil,
                                            diagnosticLoad: { pixels in try await store.artworkResult(for: album, pixels: pixels) },
                                            diagnosticService: store.artworkService) { pixels in
                            try await store.artwork(for: album, pixels: pixels)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(collection.accessibilityID + ".row")
                }
                if store.canLoadMoreAlbums && !store.albums.isEmpty {
                    Button("加载更多专辑") { Task { await store.loadMoreAlbums() } }.disabled(store.isLoading)
                }
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } else { Text("账号已退出").foregroundStyle(.secondary) }
            }.padding(20)
        }.navigationTitle("专辑").background(Color(uiColor: .systemBackground))
    }
    private var playlistPage: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], alignment: .leading, spacing: 22) {
            if store.isSignedIn {
                ForEach(store.playlists) { playlist in
                    let collection = ServerCollectionInfo(service: "subsonic", kind: .playlist, id: playlist.id,
                                                          title: playlist.name, artist: playlist.artist,
                                                          songCount: playlist.songCount, accountScope: playlist.accountScope,
                                                          artworkVersion: playlist.coverArtID)
                    NavigationLink {
                        SubsonicCollectionView(store: store, collection: collection, onPlay: onPlay,
                                               artwork: { pixels in try await store.artwork(for: playlist, pixels: pixels) },
                                               diagnosticArtwork: { pixels in try await store.artworkResult(for: playlist, pixels: pixels) }) {
                            try await store.tracks(in: playlist)
                        }
                    } label: {
                        ServerCollectionTile(collection: collection, scope: store.isSignedIn ? store.scopeID : nil,
                                            diagnosticLoad: { pixels in try await store.artworkResult(for: playlist, pixels: pixels) },
                                            diagnosticService: store.artworkService) { pixels in
                            try await store.artwork(for: playlist, pixels: pixels)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(collection.accessibilityID + ".row")
                }
                if store.playlists.isEmpty { Text("暂无歌单").foregroundStyle(.secondary) }
            } else { Text("账号已退出").foregroundStyle(.secondary) }
            }.padding(20)
        }.navigationTitle("歌单").background(Color(uiColor: .systemBackground))
    }
    private var connectionMenu: some View {
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
        HStack(spacing: 12) {
            ArtworkView(url: song.displayArtworkURL, corner: 7).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).foregroundStyle(.primary).lineLimit(1)
                Text(song.artist.isEmpty ? song.album : song.artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

@MainActor private struct SubsonicCollectionView: View {
    @ObservedObject var store: SubsonicStore
    let collection: ServerCollectionInfo
    let onPlay: ([Song], Int) -> Void
    let artwork: @MainActor (Int) async throws -> Data?
    let diagnosticArtwork: @MainActor (Int) async throws -> ServerArtworkResult
    let load: () async throws -> [Song]
    @State private var tracks: [Song] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var ticket = UUID()
    private var isCurrent: Bool { store.scopeID == collection.accountScope && store.isSignedIn }
    private var visible: [Song] { isCurrent ? tracks.filter { $0.accountScope == collection.accountScope } : [] }

    var body: some View {
        List {
            Section {
                ServerCollectionHeader(collection: collection, scope: store.isSignedIn ? store.scopeID : nil,
                                       diagnosticLoad: diagnosticArtwork, diagnosticService: store.artworkService,
                                       load: artwork)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if isCurrent {
                if loaded && !visible.isEmpty {
                    Button { onPlay(visible, 0) } label: {
                        Label("播放全部已加载曲目", systemImage: "play.fill").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier(collection.accessibilityID + ".playLoaded")
                }
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView("读取歌曲…") }
                if loaded && visible.isEmpty && !loading { Text("暂无音频曲目").foregroundStyle(.secondary) }
                // Queue positions retain server order and repeated playlist entries.
                ForEach(Array(visible.enumerated()), id: \.offset) { index, song in
                    Button { onPlay(visible, index) } label: { SubsonicSongRow(song: song) }
                }
            } else { Text("账号已变化，请返回音乐库。").foregroundStyle(.secondary) }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.scopeID) { await fetch() }
        .onChange(of: store.scopeID) { _ in
            ticket = UUID(); tracks = []; loaded = false; loading = false; error = nil
        }
        .refreshable { await fetch() }
    }
    private func fetch() async {
        guard !loading, isCurrent else { return }
        let id = UUID(); ticket = id; loading = true; error = nil
        defer { if ticket == id { loading = false } }
        do {
            let result = try await load()
            try Task.checkCancellation()
            guard ticket == id, isCurrent else { return }
            tracks = result; loaded = true
        } catch is CancellationError { }
        catch {
            guard ticket == id, !Task.isCancelled, isCurrent else { return }
            self.error = (error as? SubsonicFailure ?? .network).localizedDescription
        }
    }
}
