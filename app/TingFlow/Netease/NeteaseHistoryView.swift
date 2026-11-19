import SwiftUI

struct NeteaseHistoryView: View {
    @ObservedObject var store: NeteaseStore
    var onPlay: (([Song], Int) -> Void)? = nil
    private var records: [NeteaseRecentSong] {
        guard store.isSignedIn, let scope = store.scopeID else { return [] }
        return store.cloudRecentSongs.filter { $0.song.accountScope == scope }
    }
    var body: some View {
        List {
            if store.isSignedIn {
                Section("记录互通") {
                    Toggle("同步播放记录到网易云", isOn: Binding(get: { store.syncPlaybackHistory }, set: { store.setPlaybackHistorySync($0) }))
                        .accessibilityIdentifier("netease-history-sync")
                    Text("默认关闭。开启后只上报实际播放的网易云原平台完整音频；不补报旧记录，不上传其它服务器或换源曲目。暂停、缓冲和拖动进度不计时。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = store.historyUploadMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Text("请求被接口接受不等于立即出现在官方端或计入排行。平台可能延迟或去重；本功能不提供跨设备恢复到同一秒。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("网易云最近播放") {
                    Button("刷新云端记录") { Task { await store.refreshCloudRecentSongs() } }
                        .disabled(store.isLoadingRecentSongs)
                    if store.isLoadingRecentSongs { ProgressView("读取网易云记录…") }
                    if let message = store.recentSongsMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if records.isEmpty && !store.isLoadingRecentSongs { Text("尚无已读取的云端最近播放").foregroundStyle(.secondary) }
                    ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                        if let onPlay {
                            Button { onPlay(records.map(\.song), index) } label: { row(record) }.buttonStyle(.plain)
                        } else { row(record) }
                    }
                }
            } else {
                NavigationLink { NeteaseAccountView(store: store) } label: { Label("请先登录网易云", systemImage: "person.crop.circle") }
            }
            Section {
                Text("这里读取的是网易云云端最近播放。本机的“最近播放”仍独立保存，不会被批量上传或覆盖。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("网易云播放记录")
            .task(id: store.scopeID) { if store.isSignedIn { await store.refreshCloudRecentSongs() } }
            .refreshable { await store.refreshCloudRecentSongs() }
    }
    private func row(_ record: NeteaseRecentSong) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: record.song.artworkURL, corner: 8).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.song.title).foregroundStyle(.primary).lineLimit(2)
                Text(record.song.artist).font(.caption).foregroundStyle(.secondary)
                Text(record.playedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 52)
    }
}

struct NeteasePlaybackDiagnosticView: View {
    @ObservedObject var store: NeteaseStore
    var body: some View {
        ScrollView {
            Text(store.playbackDiagnostic ?? "尚无播放请求。请先点播一首网易云歌曲，再返回这里查看 HTTP、接口码和媒体码。")
                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle("网易云播放诊断")
    }
}
