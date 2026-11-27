import Foundation
import Combine

/// One visible song/sort/account epoch. No prefetch, auto-crawl, disk cache or write actions.
@MainActor final class SongCommentStore: ObservableObject {
    typealias Loader = @MainActor (CommentSort, Int, String?) async throws -> SongCommentPage
    enum State: Equatable {
        case idle, loading, ready, empty, end
        case failed(String), limited(String)
    }
    @Published private(set) var comments: [SongComment] = []
    @Published private(set) var total: Int?
    @Published private(set) var state: State = .idle
    private(set) var sort: CommentSort = .hot
    private(set) var nextPage = 1
    private(set) var cursor: String?
    private var context = ""
    private var loader: Loader?
    private var seenIDs = Set<String>()
    private var seenCursors = Set<String>()
    private var hasMore = true
    private var ticket = UUID()
    private var worker: Task<SongCommentPage, Error>?
    private var deadline: Task<Void, Never>?
    private let deadlineNanoseconds: UInt64
    init(deadlineNanoseconds: UInt64 = 25_000_000_000) {
        self.deadlineNanoseconds = deadlineNanoseconds
    }
    deinit { worker?.cancel(); deadline?.cancel() }
    var isLoading: Bool { state == .loading }
    var canLoadMore: Bool { hasMore && !isLoading && loader != nil }
    var errorMessage: String? { if case .failed(let message) = state { return message }; return nil }

    /// Called by a view .task(id:) keyed on song.id + commentContextID + sort.
    func open(songID: String, contextID: String, sort: CommentSort, loader: @escaping Loader) async {
        cancel(clear: true)
        context = contextID + ":" + songID
        self.sort = sort; self.loader = loader
        await loadNext()
    }
    /// Navigation/background exit cancels work, including an anonymous transport owned by NeteaseStore.
    func cancel(clear: Bool = false) {
        ticket = UUID(); worker?.cancel(); deadline?.cancel(); worker = nil; deadline = nil
        if clear {
            comments = []; total = nil; cursor = nil; nextPage = 1; hasMore = true
            seenIDs = []; seenCursors = []; loader = nil; context = ""; state = .idle
        } else if isLoading { state = comments.isEmpty ? .idle : .ready }
    }
    func loadNext() async {
        guard canLoadMore, let loader else { return }
        guard nextPage <= SongCommentMapping.maximumPages else {
            stop("已达到单次浏览上限。切换排序或重新打开可重新加载。")
            return
        }
        let token = UUID(), epoch = context, requestedPage = nextPage, requestedCursor = cursor, requestedSort = sort
        ticket = token; state = .loading
        let task = Task { @MainActor in try await loader(requestedSort, requestedPage, requestedCursor) }
        worker = task
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: self?.deadlineNanoseconds ?? 25_000_000_000) } catch { return }
            guard let self, self.ticket == token else { return }
            // Invalidate before cancelling: even a non-cooperative callback cannot publish after timeout.
            self.ticket = UUID(); task.cancel(); self.worker = nil; self.deadline = nil
            self.state = .failed(SongCommentError.timedOut.localizedDescription)
        }
        deadline = timer
        defer {
            timer.cancel()
            if ticket == token { worker = nil; deadline = nil }
        }
        do {
            let page = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard ticket == token, context == epoch else { return }
            apply(page, requestedCursor: requestedCursor)
        } catch {
            guard ticket == token, context == epoch else { return }
            if error is CancellationError || Task.isCancelled {
                state = comments.isEmpty ? .idle : .ready
            } else {
                state = .failed((error as? SongCommentError)?.localizedDescription ?? NeteaseError.message(error))
            }
        }
    }
    private func stop(_ message: String) { hasMore = false; state = .limited(message) }
    private func apply(_ page: SongCommentPage, requestedCursor: String?) {
        // Be defensive even with injected loaders: one response may never exceed the negotiated page size.
        guard page.comments.count <= SongCommentMapping.pageSize else {
            state = .failed(NeteaseError.response.localizedDescription); return
        }
        if let count = page.total, (0...1_000_000_000).contains(count) { total = count }
        var additions: [SongComment] = []
        for comment in page.comments where seenIDs.insert(comment.id).inserted { additions.append(comment) }
        comments.append(contentsOf: additions.prefix(max(0, SongCommentMapping.maximumComments - comments.count)))
        nextPage += 1
        hasMore = page.more
        if !page.more { state = comments.isEmpty ? .empty : .end; return }
        guard !additions.isEmpty else {
            stop("服务端未返回新的评论，已停止分页。可切换排序或重新打开重试。")
            return
        }
        if sort == .latest {
            guard let next = page.cursor, SongCommentMapping.validCursor(next), next != "0",
                  next != requestedCursor, seenCursors.insert(next).inserted else {
                stop("服务端未提供可继续的时间游标，已停止分页。")
                return
            }
            cursor = next
        }
        guard nextPage <= SongCommentMapping.maximumPages, comments.count < SongCommentMapping.maximumComments else {
            stop("已达到单次浏览上限，未继续请求。")
            return
        }
        state = .ready
    }
}
