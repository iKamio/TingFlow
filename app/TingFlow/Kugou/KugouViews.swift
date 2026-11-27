import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

@MainActor struct KugouAccountView: View {
    @ObservedObject var store: KugouStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section("酷狗账号 · 云端只读") {
                Text("仅展示酷狗扫码返回的账号 ID，并只读创建及收藏的歌单和歌曲。不修改酷狗喜欢、歌单或听歌记录；本机收藏与酷狗云端独立。凭据仅存于此机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.isSignedIn {
                    Text(store.accountName).font(.headline)
                    Button("退出此机酷狗账号", role: .destructive) { store.signOut() }
                }
                if store.credentialRemovalPending {
                    Text("设备凭据尚未删除。请解锁后重试；在删除成功前，重新启动可能恢复旧账号。")
                        .font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("kugou-credential-removal-pending")
                    Button("重试删除此机酷狗凭据", role: .destructive) { store.signOut() }
                        .accessibilityIdentifier("kugou-retry-credential-removal")
                }
                Button(store.isAuthorizing ? "重新生成酷狗二维码" : "用酷狗 App 扫码登录") { store.startQRCodeLogin() }
            }
            if let url = store.qrURL {
                Section("请在酷狗音乐 App 扫码确认") {
                    if let image = Self.qrImage(url) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260).padding(16).background(.white)
                            .accessibilityLabel("酷狗官方短期登录二维码")
                    } else { Text("无法绘制二维码，请取消后重试。") }
                    Text("二维码最多有效 120 秒。离开前台会暂停检查，不会延长有效期。不要将二维码分享给他人。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !store.qrStatus.isEmpty { Text(store.qrStatus).font(.footnote) }
            if store.isAuthorizing { Button("取消扫码", role: .cancel) { store.cancelQRCodeLogin() } }
            if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("酷狗账号")
            .task { store.setForeground(scenePhase == .active); await store.restore() }
            .onChange(of: scenePhase) { store.setForeground($0 == .active) }
            .onDisappear { store.cancelQRCodeLogin() }
    }
    private static func qrImage(_ url: URL) -> UIImage? {
        let f = CIFilter.qrCodeGenerator(); f.message = Data(url.absoluteString.utf8); f.correctionLevel = "M"
        guard let output = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

@MainActor struct KugouPlaylistsView: View {
    @ObservedObject var store: KugouStore
    @ObservedObject var library: LibraryStore
    let onPlay: ([Song], Int) -> Void
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                NavigationLink { KugouAccountView(store: store) } label: {
                    Label(store.isSignedIn ? store.accountName : "登录酷狗账号", systemImage: "person.crop.circle")
                }
                Text("酷狗云端只读 · 本机收藏不回写酷狗 · 播放使用已启用的 LX 音源")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.isSignedIn { Button("刷新酷狗歌单") { Task { await store.refresh() } }.disabled(store.isLoading) }
                if store.isLoading { ProgressView("正在完整读取歌单…") }
                if let message = store.errorMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if store.isSignedIn {
                playlistSection("我创建的", lists: store.createdPlaylists)
                playlistSection("我收藏的", lists: store.collectedPlaylists)
                playlistSection("其他歌单", lists: store.playlists.filter { $0.kind == .unknown })
                if !store.isLoading && store.playlists.isEmpty { Text("暂无歌单，或尚未成功读取。请刷新重试。") }
            }
        }.navigationTitle("酷狗歌单")
            .task { store.setForeground(scenePhase == .active); await store.restore() }
            .refreshable { await store.refresh() }
            .onChange(of: scenePhase) { store.setForeground($0 == .active) }
    }
    @ViewBuilder private func playlistSection(_ title: String, lists: [KugouPlaylist]) -> some View {
        if !lists.isEmpty {
            Section(title) {
                ForEach(lists) { list in
                    NavigationLink { KugouPlaylistView(store: store, library: library, playlist: list, onPlay: onPlay) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(list.name).lineLimit(2)
                            Text("\(list.trackCount) 首 · 只读").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

typealias KugouLibraryView = KugouPlaylistsView

@MainActor struct KugouPlaylistView: View {
    @ObservedObject var store: KugouStore
    @ObservedObject var library: LibraryStore
    let playlist: KugouPlaylist
    let onPlay: ([Song], Int) -> Void
    @State private var songs: [Song] = []
    @State private var loading = false
    @State private var message: String?
    @State private var reload = UUID()
    @Environment(\.scenePhase) private var scenePhase
    private var visible: [Song] {
        guard let scope = store.accountScope, scope == playlist.accountScope,
              songs.allSatisfy({ $0.accountScope == scope && $0.platform == .kugou }) else { return [] }
        return songs
    }
    var body: some View {
        List {
            Section {
                Text("酷狗云端只读。菜单中的收藏和歌单操作仅影响本机。")
                    .font(.footnote).foregroundStyle(.secondary)
                if loading { ProgressView("正在读取全部歌曲…") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button("重新读取") { reload = UUID() }.disabled(loading)
            }
            if !visible.isEmpty {
                Button { play(0) } label: { Label("播放全部", systemImage: "play.fill") }
                ForEach(Array(visible.enumerated()), id: \.offset) { index, song in
                    KugouSongRow(song: song, library: library, play: { play(index) })
                }
            } else if !loading { Text(store.accountScope == playlist.accountScope ? "暂无歌曲或尚未成功读取。" : "账号已更改，请返回重新选择歌单。") }
        }.navigationTitle(playlist.name)
            .task(id: reload) {
                store.setForeground(scenePhase == .active)
                loading = true; message = nil
                defer { loading = false }
                do { let result = try await store.tracks(in: playlist, forceReload: true); try Task.checkCancellation(); songs = result }
                catch is CancellationError { }
                catch { message = KugouError.message(error) }
            }
            .onChange(of: store.accountScope) { _ in songs = []; reload = UUID() }
            .onChange(of: scenePhase) { phase in
                store.setForeground(phase == .active)
                if phase == .active { reload = UUID() }
            }
    }
    private func play(_ index: Int) {
        let queue = visible
        guard queue.indices.contains(index) else { return }
        onPlay(queue, index)
    }
}

/// No other provider's account/environment is required, and no cloud mutation is exposed.
@MainActor private struct KugouSongRow: View {
    let song: Song
    @ObservedObject var library: LibraryStore
    let play: () -> Void
    var body: some View {
        HStack {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).foregroundStyle(.primary).lineLimit(2)
                    Text(song.artist.isEmpty ? "未知歌手 · 酷狗" : song.artist + " · 酷狗")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button(library.isFavorite(song) ? "取消本机收藏" : "仅收藏到本机") { library.toggleFavorite(song) }
                ForEach(library.playlists) { item in
                    Button("加入本机歌单：\(item.name)") { library.add(song, to: item.id) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("仅本机收藏操作，不修改酷狗云端")
        }.padding(.vertical, 4)
    }
}
