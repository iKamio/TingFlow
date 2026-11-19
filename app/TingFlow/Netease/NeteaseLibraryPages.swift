import SwiftUI

@MainActor struct NeteaseTrackList: View {
  @ObservedObject var store: NeteaseStore
  let songs: [Song]
  let onPlay: ([Song], Int) -> Void
  var body: some View {
    if !songs.isEmpty {
      Button { play(0) } label: { Label("播放全部", systemImage: "play.fill").frame(minHeight: 44) }.tint(.pink)
    }
    // Stable positions preserve repeated songs and the original queue order.
    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
        HStack(spacing: 12) {
            Button { play(index) } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: song.artworkURL, corner: 7).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                        Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            NeteaseCloudSongMenu(store: store, song: song)
        }.padding(.vertical, 3)
    }
  }
  private func play(_ index: Int) {
    guard songs.indices.contains(index), neteaseSongs(songs, in: store).count == songs.count else { return }
    onPlay(songs, index)
  }
}

struct NeteaseCoverHeader: View {
    let title: String
    let caption: String
    let url: URL?
    var body: some View {
        VStack(spacing: 14) {
            ArtworkView(url: url, corner: 16).frame(width: 200, height: 200)
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 16)
    }
}

struct NeteasePlaylistCard: View {
    let playlist: NeteasePlaylist
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistCover(url: playlist.coverURL, corner: 12, measurementID: "playlist-cover-\(playlist.id)")
            Text(playlist.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 4) {
                if playlist.isPrivate { Image(systemName: "lock.fill").accessibilityLabel("私密歌单") }
                if playlist.isLiked { Image(systemName: "heart.fill").foregroundStyle(.pink).accessibilityLabel("我喜欢的音乐") }
                Text("\(playlist.trackCount) 首").lineLimit(1, reservesSpace: true)
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
    }
}

struct NeteasePageMessage: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}

@MainActor struct NeteaseLoginPrompt: View {
    @ObservedObject var store: NeteaseStore
    var body: some View {
        NavigationLink { NeteaseAccountView(store: store) } label: {
            Label("登录网易云，查看你的音乐", systemImage: "person.crop.circle")
                .frame(minHeight: 44)
        }
    }
}

@MainActor func neteaseSongs(_ songs: [Song], in store: NeteaseStore) -> [Song] {
    guard store.isSignedIn, let scope = store.scopeID,
          songs.allSatisfy({ $0.accountScope == scope }) else { return [] }
    return songs
}

@MainActor func neteaseRecommendationError(_ store: NeteaseStore, prefix: String) -> String? {
    let messages = store.recommendationError?.components(separatedBy: "；").filter { $0.hasPrefix(prefix) } ?? []
    return messages.isEmpty ? nil : messages.joined(separator: "；")
}

@MainActor struct NeteaseDailySongsView: View {
  @ObservedObject var store: NeteaseStore
  let onPlay: ([Song], Int) -> Void
  @State private var contentID = UUID()
  init(store: NeteaseStore, onPlay: @escaping ([Song], Int) -> Void) { self.store = store; self.onPlay = onPlay }
  private var songs: [Song] { neteaseSongs(store.dailySongs, in: store) }
  var body: some View {
    List {
      if store.isSignedIn {
        NeteaseCoverHeader(title: "每日推荐", caption: "\(Date.now.formatted(date: .long, time: .omitted)) · \(songs.count) 首", url: songs.first?.artworkURL)
        NeteaseLoadState(title: "每日推荐", loading: store.isLoadingRecommendations, error: neteaseRecommendationError(store, prefix: "每日歌曲："), empty: songs.isEmpty)
        NeteaseTrackList(store: store, songs: songs, onPlay: onPlay)
      } else { NeteaseLoginPrompt(store: store) }
    }
    .id(contentID).listStyle(.plain).navigationTitle("每日推荐").navigationBarTitleDisplayMode(.inline)
    .refreshable { await store.refreshRecommendations() }
    .onChange(of: store.scopeID) { _ in contentID = UUID() }
  }
}

@MainActor struct NeteaseMyPlaylistsView: View {
  @ObservedObject var store: NeteaseStore
  let onPlay: ([Song], Int) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var filter = Filter.all
  private enum Filter: String, CaseIterable { case created = "我创建的", subscribed = "我收藏的", all = "全部" }
  init(store: NeteaseStore, onPlay: @escaping ([Song], Int) -> Void) { self.store = store; self.onPlay = onPlay }
  private var playlists: [NeteasePlaylist] {
    guard store.isSignedIn, let scope = store.scopeID else { return [] }
    let source: [NeteasePlaylist]
    switch filter {
    case .all: source = store.playlists
    case .created: source = store.createdPlaylists
    case .subscribed: source = store.subscribedPlaylists
    }
    return source.filter { $0.accountScope == scope }
  }
  private var picker: some View {
    Picker("歌单分类", selection: $filter) {
      ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }.frame(minHeight: 44)
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if store.isSignedIn {
          if typeSize > .large { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
          Text("\(playlists.count) 张歌单").font(.subheadline).foregroundStyle(.secondary)
          NeteaseLoadState(title: "歌单", loading: store.isLoading, error: store.errorMessage, empty: playlists.isEmpty)
          NeteasePlaylistGrid(store: store, playlists: playlists, onPlay: onPlay)
        } else { NeteaseLoginPrompt(store: store) }
      }.padding(16)
    }
    .id(store.scopeID).navigationTitle("我的歌单")
    .refreshable { await store.refresh() }
    .onChange(of: store.scopeID) { _ in filter = .all }
  }
}

@MainActor struct NeteaseRecommendationsView: View {
  enum Kind: Equatable {
    case daily, featured
    var title: String { self == .daily ? "每日歌单" : "精选歌单" }
  }
  @ObservedObject var store: NeteaseStore
  let kind: Kind
  let onPlay: ([Song], Int) -> Void
  @State private var contentID = UUID()
  init(store: NeteaseStore, kind: Kind, onPlay: @escaping ([Song], Int) -> Void) { self.store = store; self.kind = kind; self.onPlay = onPlay }
  private var playlists: [NeteasePlaylist] {
    guard store.isSignedIn, let scope = store.scopeID else { return [] }
    return (kind == .daily ? store.dailyPlaylists : store.personalizedPlaylists).map {
      NeteasePlaylist(id: $0.id, name: $0.name, trackCount: $0.trackCount, coverURL: $0.coverURL, ownerName: "", accountScope: scope)
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if store.isSignedIn {
          Text("\(playlists.count) 张歌单").font(.subheadline).foregroundStyle(.secondary)
          NeteaseLoadState(title: kind.title, loading: store.isLoadingRecommendations, error: neteaseRecommendationError(store, prefix: kind == .daily ? "每日歌单：" : "精选歌单："), empty: playlists.isEmpty)
          NeteasePlaylistGrid(store: store, playlists: playlists, onPlay: onPlay)
          if kind == .daily {
            NavigationLink("浏览精选歌单") { NeteaseRecommendationsView(store: store, kind: .featured, onPlay: onPlay) }.frame(minHeight: 44).tint(.pink)
          }
        } else { NeteaseLoginPrompt(store: store) }
      }.padding(16)
    }
    .id(contentID).navigationTitle(kind.title)
    .refreshable { await store.refreshRecommendations() }
    .onChange(of: store.scopeID) { _ in contentID = UUID() }
  }
}

@MainActor struct NeteaseFMView: View {
  @ObservedObject var store: NeteaseStore
  let onPlay: ([Song], Int) -> Void
  @State private var contentID = UUID()
  @State private var request: Task<Void, Never>?
  init(store: NeteaseStore, onPlay: @escaping ([Song], Int) -> Void) { self.store = store; self.onPlay = onPlay }
  private var songs: [Song] { neteaseSongs(store.fmSongs, in: store) }
  var body: some View {
    List {
      if store.isSignedIn {
        Text("\(songs.count) 首 · 按需获取，不会自动换一批").font(.subheadline).foregroundStyle(.secondary)
        Button { request = Task { await store.loadPersonalFM() } } label: {
          Label(songs.isEmpty ? "获取私人 FM" : "换一批", systemImage: "arrow.clockwise").frame(minHeight: 44)
        }.tint(.pink).disabled(store.isLoadingFM)
        NeteaseLoadState(title: "私人 FM", loading: store.isLoadingFM, error: store.fmError, empty: songs.isEmpty)
        NeteaseTrackList(store: store, songs: songs, onPlay: onPlay)
      } else { NeteaseLoginPrompt(store: store) }
    }
    .id(contentID).listStyle(.plain).navigationTitle("私人 FM").navigationBarTitleDisplayMode(.inline)
    .onChange(of: store.scopeID) { _ in request?.cancel(); request = nil; contentID = UUID() }
  }
}

struct NeteaseLoadState: View {
  let title: String
  let loading: Bool
  let error: String?
  let empty: Bool
  var body: some View {
    if loading { ProgressView("正在读取\(title)…") }
    if let error { NeteasePageMessage(title: "\(title)未能更新", detail: error) }
    else if empty && !loading { NeteasePageMessage(title: "暂无\(title)") }
  }
}

@MainActor struct NeteasePlaylistGrid: View {
  @ObservedObject var store: NeteaseStore
  let playlists: [NeteasePlaylist]
  let onPlay: ([Song], Int) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  var body: some View {
    LazyVGrid(columns: typeSize.isAccessibilitySize
              ? [GridItem(.flexible(), spacing: 16, alignment: .top)]
              : [GridItem(.adaptive(minimum: typeSize > .large ? 200 : 150), spacing: 16, alignment: .top)],
              alignment: .leading, spacing: 20) {
      ForEach(Array(playlists.enumerated()), id: \.offset) { _, playlist in
        NavigationLink { NeteasePlaylistView(store: store, playlist: playlist, onPlay: onPlay) } label: {
          VStack(alignment: .leading, spacing: 4) {
            NeteasePlaylistCard(playlist: playlist)
            // Keep the optional ownership line's slot even when it is absent.
            Text(playlist.ownerID.map { $0 == store.currentUserID ? "我创建的" : "我收藏的" } ?? " ")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1, reservesSpace: true)
              .accessibilityHidden(playlist.ownerID == nil)
          }.frame(maxWidth: .infinity, alignment: .topLeading)
        }.buttonStyle(.plain)
          .accessibilityIdentifier("playlist-card-\(playlist.id)")
      }
    }
  }
}
