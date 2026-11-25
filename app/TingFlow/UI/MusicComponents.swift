import SwiftUI

struct ArtworkView: View {
    var url: URL?
    var corner: CGFloat = 10
    @State private var image: UIImage?
    var body: some View {
        // Only the shape participates in layout. An image's decoded dimensions
        // must never change a grid cell, including while the image is loading.
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.tertiary)
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
            }
        .task(id: url) {
            image = nil
            guard let url else { return }
            #if DEBUG
            if let fixture = UIPolishFixture.image(url) { image = fixture; return }
            #endif
            if let data = try? await ArtworkLoader.shared.data(url), !Task.isCancelled {
                image = ArtworkLoader.thumbnail(data)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct TrackRowView: View {
    @EnvironmentObject private var netease: NeteaseStore
    let song: Song
    let play: () -> Void
    @ObservedObject var library: LibraryStore
    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ArtworkView(url: song.displayArtworkURL, corner: 7).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).foregroundStyle(.primary).lineLimit(1)
                        Text("\(song.artist) · \(song.platform.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button(library.isFavorite(song) ? "取消本机收藏" : "仅收藏到本机", action: { library.toggleFavorite(song) })
                ForEach(library.playlists) { playlist in
                    Button("加入本机歌单：\(playlist.name)") { library.add(song, to: playlist.id) }
                }
            } label: {
                Image(systemName: library.isFavorite(song) ? "bookmark.fill" : "ellipsis")
                    .frame(width: 40, height: 44)
            }.accessibilityLabel("\(song.title)的本机收藏操作")
            if song.platform == .netease { NeteaseCloudSongMenu(store: netease, song: song) }
        }.padding(.vertical, 3)
    }
}

struct LocalTrackListView: View {
    let title: String
    let songs: [Song]
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    private var visible: [Song] {
        songs.filter { song in song.accountScope.map { library.activeScopes.contains($0) } ?? true }
    }
    var body: some View {
        List {
            if visible.isEmpty { Text("暂无歌曲").foregroundStyle(.secondary) }
            else {
                Button { player.play(visible, at: 0) } label: { Label("播放全部", systemImage: "play.fill") }
                ForEach(Array(visible.enumerated()), id: \.offset) { index, song in
                    TrackRowView(song: song, play: { player.play(visible, at: index) }, library: library)
                }
            }
        }.listStyle(.plain).navigationTitle(title)
    }
}

struct ConnectionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.pink).frame(width: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

