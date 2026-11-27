import SwiftUI

/// Present in a sheet: SongCommentsView(song: song).environmentObject(netease).
/// Pass the actual current Song; never search by title or substitute a recommendation ID.
@MainActor struct SongCommentsView: View {
    let song: Song
    @EnvironmentObject private var netease: NeteaseStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SongCommentStore()
    @State private var sort: CommentSort = .hot
    private struct RequestIdentity: Equatable {
        let song: String
        let account: String
        let sort: CommentSort
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: String(song.title.prefix(200))).font(.headline).lineLimit(2)
                    Text(verbatim: String(song.artist.prefix(200))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let total = model.total {
                        Text("共 \(total) 条评论").font(.subheadline).accessibilityIdentifier("song-comments-total")
                    }
                    Picker("评论排序", selection: $sort) {
                        ForEach(CommentSort.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("song-comments-sort")
                    Text("仅供浏览；不支持发布、点赞或回复。").font(.caption).foregroundStyle(.secondary)
                }.padding()
                List {
                    ForEach(model.comments) { comment in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: comment.nickname).font(.subheadline.weight(.semibold))
                                Spacer()
                                Label("\(comment.likes)", systemImage: "heart").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(verbatim: comment.content).font(.body).textSelection(.enabled)
                            if let quote = comment.quote {
                                Text(verbatim: quote).font(.callout).foregroundStyle(.secondary)
                                    .padding(.leading, 10).accessibilityLabel("引用：" + quote)
                            }
                            if let time = comment.time { Text(time, style: .date).font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6).accessibilityElement(children: .contain)
                            .accessibilityIdentifier("song-comment-" + comment.id)
                    }
                    status
                }.listStyle(.plain).accessibilityIdentifier("song-comments-list")
            }
            .navigationTitle("歌曲评论").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { model.cancel(clear: true); dismiss() }.accessibilityIdentifier("song-comments-close")
            } }
        }
        .task(id: RequestIdentity(song: song.id, account: netease.commentContextID, sort: sort)) {
            guard song.platform == .netease else { model.cancel(clear: true); return }
            #if DEBUG
            if let loader = SongCommentsUIFixture.makeLoader() {
                await model.open(songID: song.id, contextID: netease.commentContextID, sort: sort, loader: loader)
                return
            }
            #endif
            await model.open(songID: song.id, contextID: netease.commentContextID, sort: sort) { requestedSort, page, cursor in
                try await netease.comments(for: song, sort: requestedSort, page: page, cursor: cursor)
            }
        }
        .onDisappear { model.cancel(clear: true) }
        .onChange(of: scenePhase) { if $0 != .active { model.cancel() } }
    }
    @ViewBuilder private var status: some View {
        switch model.state {
        case .loading:
            HStack { Spacer(); ProgressView("正在加载评论…"); Spacer() }.accessibilityIdentifier("song-comments-loading")
        case .failed(let message):
            Text(verbatim: message).foregroundStyle(.secondary).accessibilityIdentifier("song-comments-error")
            Button("重试") { Task { await model.loadNext() } }.accessibilityIdentifier("song-comments-retry")
        case .empty:
            Text("暂无评论").foregroundStyle(.secondary).accessibilityIdentifier("song-comments-empty")
        case .end:
            Text("已显示全部可用评论").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("song-comments-end")
        case .limited(let reason):
            Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("song-comments-limit")
        case .idle, .ready:
            if song.platform != .netease {
                Text("仅支持网易云歌曲评论").foregroundStyle(.secondary)
            } else if model.canLoadMore {
                Button(model.comments.isEmpty ? "加载评论" : "加载更多") { Task { await model.loadNext() } }
                    .accessibilityIdentifier("song-comments-more")
            }
        }
    }
}

#if DEBUG
/// Synthetic text ONLY. This branch and launch-argument strings are absent from Release.
/// Requires the existing polish fixture too; it never intercepts the production transport.
@MainActor private enum SongCommentsUIFixture {
    static func makeLoader() -> SongCommentStore.Loader? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-TingFlowPolishFixture"),
              let index = arguments.firstIndex(of: "-TingFlowSongCommentsFixture"),
              arguments.indices.contains(index + 1) else { return nil }
        let scenario = arguments[index + 1]
        var attempts = 0
        return { sort, page, _ in
            attempts += 1
            if scenario == "loading" { try await Task.sleep(nanoseconds: 60_000_000_000) }
            try Task.checkCancellation()
            if scenario == "error" && attempts == 1 { throw NeteaseError.network }
            if scenario == "empty" { return SongCommentPage(comments: [], total: 0, more: false, cursor: nil) }
            let suffix = sort == .hot ? "热门" : "最新"
            let row = SongComment(id: "\(sort.rawValue)\(page)", nickname: "合成测试用户", content: "合成\(suffix)评论第\(page)页 <b>纯文本</b> https://example.invalid/",
                                  time: nil, likes: 0, quote: nil)
            return SongCommentPage(comments: [row], total: 2, more: page == 1, cursor: page == 1 ? "1700000000000" : nil)
        }
    }
}
#endif
