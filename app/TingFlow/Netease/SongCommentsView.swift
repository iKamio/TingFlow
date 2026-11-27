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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    songHeader
                    HStack(alignment: .firstTextBaseline) {
                        Text(sort == .hot ? "热门评论" : "最新评论").font(.title3.bold())
                        Spacer()
                        if let total = model.total {
                            Text("\(total) 条").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityLabel("共 \(total) 条评论")
                                .accessibilityIdentifier("song-comments-total")
                        }
                    }.padding(.top, 8)
                    Picker("评论排序", selection: $sort) {
                        ForEach(CommentSort.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("song-comments-sort")
                    ForEach(model.comments) { comment in
                        SongCommentRow(comment: comment)
                    }
                    status
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }.padding(20).accessibilityIdentifier("song-comments-list")
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
    private var songHeader: some View {
        HStack(spacing: 14) {
            ArtworkView(url: song.displayArtworkURL, corner: 12).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: String(song.title.prefix(200))).font(.headline).lineLimit(2)
                Text(verbatim: String(song.artist.prefix(200))).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

private struct SongCommentRow: View {
    let comment: SongComment
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(comment.nickname.prefix(1)))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.pink)
                    .frame(width: 36, height: 36)
                    .background(Color.pink.opacity(0.09), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: comment.nickname).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let time = comment.time {
                        Text(time, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Label("\(comment.likes)", systemImage: "heart")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                    .accessibilityLabel("\(comment.likes) 次赞")
            }
            Text(verbatim: comment.content).font(.body).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let quote = comment.quote {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.pink.opacity(0.3)).frame(width: 3)
                    Text(verbatim: quote).font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore).accessibilityLabel("引用：" + quote)
            }
        }.padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("song-comment-" + comment.id)
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
