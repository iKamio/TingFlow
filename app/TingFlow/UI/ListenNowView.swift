import SwiftUI

struct CollectionTile: View {
    let title: String
    let detail: String
    let url: URL?
    var symbol: String = "music.note.list"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaylistCover(url: url, corner: 18, measurementID: "collection-cover-\(title)")
                .overlay(alignment: .bottomLeading) {
                    if url == nil {
                        LinearGradient(colors: [.pink.opacity(0.18), .orange.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(alignment: .bottomLeading) {
                                Image(systemName: symbol).font(.system(size: 36, weight: .semibold))
                                    .foregroundStyle(.pink).padding(18)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityHidden(true)
                    }
                }
            Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2, reservesSpace: true)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
    }
}

struct ListenNowView: View {
    @EnvironmentObject private var subsonic: SubsonicStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var library: LibraryStore
    @ObservedObject var emby: EmbyStore
    @ObservedObject var netease: NeteaseStore
    @ObservedObject var player: PlayerStore
    let connect: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if netease.isSignedIn {
                    HStack { Text("为你精选").font(.title2.bold()); Spacer(); Text("网易云音乐").font(.caption).foregroundStyle(.secondary) }
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            NavigationLink { NeteaseDailySongsView(store: netease, onPlay: play) } label: {
                                CollectionTile(title: "每日推荐", detail: "\(netease.dailySongs.count) 首 · 每天新的灵感", url: netease.dailySongs.first?.artworkURL, symbol: "calendar")
                            }
                            .frame(width: typeSize.isAccessibilitySize ? 260 : 220)
                            NavigationLink { NeteaseFMView(store: netease, onPlay: play) } label: {
                                CollectionTile(title: "私人 FM", detail: "为你而来的下一首", url: netease.fmSongs.first?.artworkURL, symbol: "dot.radiowaves.left.and.right")
                            }.frame(width: typeSize.isAccessibilitySize ? 260 : 220)
                        }.buttonStyle(.plain).padding(.horizontal, 20)
                    }
                    sectionHeader("我的歌单") { NeteaseMyPlaylistsView(store: netease, onPlay: play) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(netease.playlists.prefix(6).enumerated()), id: \.offset) { _, list in
                                NavigationLink { NeteasePlaylistView(store: netease, playlist: list, onPlay: play) } label: {
                                    NeteasePlaylistCard(playlist: list).frame(width: 160)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 20)
                    }
                    NavigationLink { NeteaseRecommendationsView(store: netease, kind: .daily, onPlay: play) } label: {
                        ConnectionCard(title: "发现更多歌单", subtitle: "每日歌单 · 网易云精选", symbol: "square.grid.2x2")
                    }.buttonStyle(.plain).padding(.horizontal, 20)
                }
                LazyVGrid(columns: typeSize.isAccessibilitySize
                          ? [GridItem(.flexible(), spacing: 16, alignment: .top)]
                          : [GridItem(.adaptive(minimum: 145), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    NavigationLink { LocalTrackListView(title: "最近播放", songs: library.recentSongs(), library: library, player: player) } label: {
                        CollectionTile(title: "接着听", detail: "最近播放 · \(library.recentSongs().count) 首", url: library.recentSongs().first?.artworkURL, symbol: "clock")
                    }
                    NavigationLink { LocalTrackListView(title: "我的收藏", songs: library.favoriteSongs(), library: library, player: player) } label: {
                        CollectionTile(title: "我的收藏", detail: "留给喜欢的旋律", url: library.favoriteSongs().first?.artworkURL, symbol: "heart.fill")
                    }
                }.buttonStyle(.plain).padding(.horizontal, 20)
                if emby.isSignedIn || subsonic.isSignedIn {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("我的音乐库").font(.title2.bold())
                        if emby.isSignedIn {
                            NavigationLink { EmbyLibraryView(store: emby, onPlay: play) } label: {
                                ConnectionCard(title: "Emby", subtitle: "专辑、歌单与歌曲", symbol: "hifispeaker.fill")
                            }
                        }
                        if subsonic.isSignedIn {
                            NavigationLink { SubsonicLibraryView(store: subsonic, onPlay: play) } label: {
                                ConnectionCard(title: subsonic.serviceLabel, subtitle: "专辑与歌单", symbol: "externaldrive.fill")
                            }
                        }
                    }.buttonStyle(.plain).padding(.horizontal, 20)
                }
                if !netease.isSignedIn {
                    Button(action: connect) {
                        ConnectionCard(title: "连接你的音乐", subtitle: "网易云账号 · 自己的音乐服务器", symbol: "person.crop.circle")
                    }.buttonStyle(.plain).padding(.horizontal, 20)
                }
            }.padding(.vertical, 16).padding(.bottom, 12)
        }.background(Color(uiColor: .systemBackground)).navigationTitle("现在就听")
            .refreshable { if netease.isSignedIn { await netease.refresh() } }
    }
    private func play(_ songs: [Song], _ index: Int) { player.play(songs, at: index) }
    private func sectionHeader<Destination: View>(_ title: String, @ViewBuilder destination: () -> Destination) -> some View {
        HStack { Text(title).font(.title2.bold()); Spacer(); NavigationLink(destination: destination) { Text("查看全部").font(.subheadline).frame(minHeight: 44) } }
            .padding(.horizontal, 20)
    }
}
