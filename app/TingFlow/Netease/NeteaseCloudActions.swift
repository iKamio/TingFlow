import SwiftUI

/// A cloud heart is intentionally separate from LibraryStore's on-device favorites.
struct NeteaseCloudLikeButton: View {
    @ObservedObject var store: NeteaseStore
    let song: Song
    var iconOnly = true
    @State private var working = false
    @State private var notice: String?
    private var needsReview: Bool { store.cloudNeedsReview.contains("like:" + song.platformID) }
    private var isCurrent: Bool {
        song.platform == .netease && store.isSignedIn &&
            (song.accountScope == nil || song.accountScope == store.scopeID)
    }
    private var label: String {
        if needsReview || !store.hasLoadedLikes { return "刷新网易云喜欢状态" }
        return store.isCloudLiked(song) ? "取消网易云喜欢" : "喜欢并同步到网易云"
    }
    var body: some View {
        Button { change() } label: {
            HStack(spacing: 8) {
                if working || store.isLoadingLikes { ProgressView() }
                else { Image(systemName: needsReview ? "arrow.clockwise" : (store.isCloudLiked(song) ? "heart.fill" : "heart")) }
                if !iconOnly { Text(label) }
            }.frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(store.isCloudLiked(song) ? Color.pink : .primary)
        }.buttonStyle(.plain).disabled(!isCurrent || working || !store.cloudPending.isEmpty)
            .accessibilityLabel(label).accessibilityIdentifier("netease-cloud-like")
            .task(id: store.scopeID) {
                if isCurrent && !store.hasLoadedLikes { await store.refreshCloudLikes() }
            }
            .alert("网易云同步", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("知道了", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
    }
    private func change() {
        guard isCurrent, !working else { return }
        working = true
        Task {
            defer { working = false }
            if needsReview || !store.hasLoadedLikes {
                await store.refreshCloudLikes(); notice = store.cloudMessage
                return
            }
            let target = !store.isCloudLiked(song)
            do {
                try await store.setCloudLiked(song, liked: target)
                notice = target ? "已确认加入网易云“我喜欢的音乐”。" : "已确认取消网易云喜欢。"
            } catch { notice = NeteaseCloudUI.message(error) }
        }
    }
}

enum NeteaseCloudUI {
    static func message(_ error: Error) -> String {
        if let value = error as? NeteaseCloudFailure { return value.localizedDescription }
        if let value = error as? NeteaseError { return value.localizedDescription }
        if error is CancellationError { return "操作已取消；如已发出请求，请刷新云端状态确认。" }
        return "本次同步未能确认，请刷新网易云状态后查看。不会自动重复写入。"
    }
}

struct NeteaseCloudSongMenu: View {
    @ObservedObject var store: NeteaseStore
    let song: Song
    @State private var selectPlaylist = false
    @State private var working = false
    @State private var notice: String?
    var body: some View {
        Menu {
            Button(store.isCloudLiked(song) ? "取消网易云喜欢" : "喜欢并同步到网易云") {
                let liked = !store.isCloudLiked(song)
                working = true
                Task {
                    defer { working = false }
                    do { try await store.setCloudLiked(song, liked: liked); notice = "已从网易云读回确认喜欢状态。" }
                    catch { notice = NeteaseCloudUI.message(error) }
                }
            }
            Button("加入网易云歌单…") { selectPlaylist = true }
            Text("这是网易云云端操作，不是本机收藏。")
        } label: { Image(systemName: "ellipsis").frame(width: 40, height: 44) }
            .disabled(!store.isSignedIn || song.platform != .netease || working || !store.cloudPending.isEmpty)
            .accessibilityLabel("网易云喜欢与歌单操作")
            .alert("网易云同步", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("知道了", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
            .sheet(isPresented: $selectPlaylist) {
                NavigationStack { NeteaseAddToPlaylistView(store: store, song: song) }
            }
    }
}

private struct NeteaseAddToPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: NeteaseStore
    let song: Song
    @State private var chosen: NeteasePlaylist?
    @State private var working = false
    @State private var notice: String?
    private var lists: [NeteasePlaylist] {
        store.createdPlaylists.filter { $0.accountScope == store.scopeID && !$0.isLiked }
    }
    var body: some View {
        List {
            Section {
                Text(song.title).font(.headline)
                Text("只显示你创建的网易云歌单。确认后会写入网易云，并读回核验；不修改本机歌单。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("刷新我的网易云歌单") { Task { await store.refreshCloudPlaylists() } }
                    .disabled(working || !store.cloudPending.isEmpty)
            }
            if !store.isSignedIn { Text("账号已退出，请重新登录。").foregroundStyle(.secondary) }
            else {
                ForEach(Array(lists.enumerated()), id: \.offset) { _, list in
                    Button { chosen = list } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: list.coverURL, corner: 7).frame(width: 44, height: 44)
                            Text(list.name).foregroundStyle(.primary).lineLimit(2)
                        }
                    }.disabled(working || !store.cloudPending.isEmpty)
                }
                if lists.isEmpty { Text("暂无可添加的自建歌单，请先在网易云创建或刷新。").foregroundStyle(.secondary) }
            }
            if working { ProgressView("正在写入并核验…") }
            if let message = store.cloudMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("加入网易云歌单")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("添加“\(song.title)”到“\(chosen?.name ?? "")”？", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }), titleVisibility: .visible) {
                if let list = chosen {
                    Button("添加到网易云歌单") {
                        chosen = nil; working = true
                        Task {
                            defer { working = false }
                            do { try await store.addCloudSong(song, to: list); notice = "已从网易云读回确认，歌曲在目标歌单中。" }
                            catch { notice = NeteaseCloudUI.message(error) }
                        }
                    }
                }
                Button("取消", role: .cancel) { chosen = nil }
            }
            .alert("网易云同步", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("知道了", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
    }
}

struct NeteaseCloudPlaylistButton: View {
    @ObservedObject var store: NeteaseStore
    let playlist: NeteasePlaylist
    @State private var confirm = false
    @State private var working = false
    @State private var notice: String?
    private var isOwn: Bool { playlist.ownerID == store.currentUserID && playlist.ownerID != nil }
    private var subscribed: Bool { store.playlists.contains { $0.id == playlist.id } }
    var body: some View {
        if store.isSignedIn && !isOwn && playlist.accountScope == store.scopeID {
            Button { confirm = true } label: {
                HStack {
                    Label(subscribed ? "取消网易云收藏歌单" : "收藏歌单到网易云", systemImage: subscribed ? "checkmark.icloud" : "icloud.and.arrow.up")
                    if working { Spacer(); ProgressView() }
                }.frame(minHeight: 44)
            }.disabled(working || !store.cloudPending.isEmpty)
                .confirmationDialog(subscribed ? "取消网易云中的这张收藏歌单？" : "将这张歌单收藏到网易云？", isPresented: $confirm, titleVisibility: .visible) {
                    Button(subscribed ? "取消网易云收藏" : "收藏到网易云", role: subscribed ? .destructive : nil) {
                        let target = !subscribed; working = true
                        Task {
                            defer { working = false }
                            do { try await store.setCloudPlaylistSubscribed(playlist, subscribed: target); notice = "已读回网易云歌单列表并确认。" }
                            catch { notice = NeteaseCloudUI.message(error) }
                        }
                    }
                    Button("取消", role: .cancel) { }
                }
                .alert("网易云同步", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                    Button("知道了", role: .cancel) { notice = nil }
                } message: { Text(notice ?? "") }
        }
    }
}
