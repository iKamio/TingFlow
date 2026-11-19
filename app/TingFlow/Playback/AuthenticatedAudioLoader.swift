import AVFoundation
import UniformTypeIdentifiers

/// All mutable loader/transfer state is confined to `work`; credentials never enter the asset URL.
final class AuthenticatedAudioLoader: NSObject, AVAssetResourceLoaderDelegate {
    private final class Job {
        let request: AVAssetResourceLoadingRequest
        let limit: Int64?
        let infoOnly: Bool
        var position: Int64
        var end: Int64 = 0
        var remaining: Int64 = 0
        var accepted = false
        var task: URLSessionDataTask?
        init(_ request: AVAssetResourceLoadingRequest) throws {
            self.request = request
            let data = request.dataRequest
            infoOnly = data == nil || (data!.requestedLength == 0 && !data!.requestsAllDataToEndOfResource)
            position = infoOnly ? 0 : max(data!.requestedOffset, data!.currentOffset)
            if let data, !infoOnly, !data.requestsAllDataToEndOfResource {
                let (end, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                guard !overflow, data.requestedLength >= 0, position <= end else { throw PlaybackFailure.range }
                limit = end
            } else { limit = nil }
            guard position >= 0, (data?.requestedOffset ?? 0) >= 0 else { throw PlaybackFailure.range }
        }
    }
    // URLSession retains its delegate; the weak forwarding link breaks that cycle.
    private final class Bridge: NSObject, URLSessionDataDelegate {
        weak var owner: AuthenticatedAudioLoader?
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner else { completionHandler(.cancel); return }
            owner.response(dataTask, response, completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.receive(dataTask, data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.complete(task, error)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // Reject ALL redirects, including same-origin ones.
            if let owner, let job = owner.transfers[task.taskIdentifier] { owner.finish(job, .redirect) }
        }
    }
    private let work = DispatchQueue(label: "TingFlow.AudioRange")
    private let resource: PlaybackResource
    private let assetURL: URL
    private let onFailure: (PlaybackFailure) -> Void
    private var session: URLSession!
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var transfers: [Int: Job] = [:]
    private var total: Int64?
    private var invalidated = false

    init(_ resource: PlaybackResource, onFailure: @escaping (PlaybackFailure) -> Void) throws {
        try PlaybackPolicy.validateURL(resource.url)
        let blocked = ["host", "cookie", "range", "accept-encoding", "content-length", "connection", "transfer-encoding"]
        for (key, value) in resource.headers {
            guard !blocked.contains(key.lowercased()), !key.isEmpty,
                  key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }),
                  !value.contains("\r"), !value.contains("\n") else { throw PlaybackFailure.source }
        }
        self.resource = resource; self.onFailure = onFailure
        assetURL = URL(string: "tingflow-audio://\(UUID().uuidString)/audio")!
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        let delegate = Bridge(); delegate.owner = self
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.underlyingQueue = work
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    }
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: work)
        return asset
    }
    func invalidate() {
        work.async { [self] in
            invalidated = true
            for job in Array(jobs.values) { finish(job, cancelled: true) }
            session.invalidateAndCancel()
        }
    }
    deinit { session?.invalidateAndCancel() }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !invalidated, request.request.url == assetURL, jobs.count < 4 else {
            request.finishLoading(with: PlaybackFailure.source); return true
        }
        do {
            let job = try Job(request); jobs[ObjectIdentifier(request)] = job; launch(job)
        } catch { request.finishLoading(with: PlaybackFailure.range) }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        if let job = jobs[ObjectIdentifier(request)] { finish(job, cancelled: true) }
    }
    private func launch(_ job: Job) {
        if let total, job.position >= total {
            finish(job, job.position == total ? nil : .range); return
        }
        if !job.infoOnly, let limit = job.limit, job.position >= limit { finish(job); return }
        var count = min(PlaybackPolicy.chunk, Int64.max - job.position)
        if job.infoOnly { count = min(count, 2) }
        if let limit = job.limit { count = min(count, limit - job.position) }
        if let total { count = min(count, total - job.position) }
        guard count > 0 else { finish(job, .range); return }
        job.end = job.position + count - 1; job.accepted = false
        var request = URLRequest(url: resource.url)
        for (key, value) in resource.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(job.position)-\(job.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        job.task = task; transfers[task.taskIdentifier] = job; task.resume()
    }
    private func response(_ task: URLSessionDataTask, _ response: URLResponse,
                          _ completion: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = transfers[task.taskIdentifier] else { completion(.cancel); return }
        do {
            guard let http = response as? HTTPURLResponse, http.url == resource.url else { throw PlaybackFailure.source }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else { throw PlaybackFailure.range }
            let length: Int64, size: Int64
            if http.statusCode == 206 {
                let range = try AudioByteRange(http.value(forHTTPHeaderField: "Content-Range") ?? "")
                try range.validate(start: job.position, end: job.end, knownTotal: total)
                length = range.length; size = range.total
                if let field = http.value(forHTTPHeaderField: "Content-Length"), Int64(field) != length { throw PlaybackFailure.range }
            } else if http.statusCode == 200 {
                // An ignored Range is safe only for a complete, small, offset-zero response.
                guard job.position == 0, let field = http.value(forHTTPHeaderField: "Content-Length"),
                      let n = Int64(field), n > 0, n <= job.end + 1,
                      total == nil || total == n else { throw PlaybackFailure.range }
                length = n; size = n
            } else { throw PlaybackFailure.http(http.statusCode) }
            guard length <= PlaybackPolicy.chunk else { throw PlaybackFailure.range }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard !mime.contains("mpegurl"), !mime.contains("dash"),
                  mime.hasPrefix("audio/") || mime == "application/octet-stream" || mime == "application/ogg" else { throw PlaybackFailure.format }
            let ext = resource.url.pathExtension.lowercased()
            let hint = (resource.mimeType ?? "").components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
            let trustedType = hint.hasPrefix("audio/") && !hint.contains("mpegurl") && !hint.contains("dash") ? UTType(mimeType: hint) : nil
            let type = mime == "application/octet-stream"
                ? (trustedType ?? (["mp3", "m4a", "aac", "flac", "wav", "aiff", "caf", "ogg"].contains(ext) ? UTType(filenameExtension: ext) : nil))
                : UTType(mimeType: mime)
            guard let type else { throw PlaybackFailure.format }
            total = size
            if let info = job.request.contentInformationRequest {
                info.contentLength = size; info.contentType = type.identifier
                info.isByteRangeAccessSupported = http.statusCode == 206
            }
            if job.infoOnly { finish(job); completion(.cancel); return }
            job.remaining = length; job.accepted = true; completion(.allow)
        } catch {
            finish(job, (error as? PlaybackFailure) ?? .range); completion(.cancel)
        }
    }
    private func receive(_ task: URLSessionDataTask, _ data: Data) {
        guard let job = transfers[task.taskIdentifier] else { return }
        guard job.accepted, Int64(data.count) <= job.remaining else { finish(job, .range); return }
        // No accumulated Data: URLSession's delivered chunk is immediately consumed by AVFoundation.
        job.request.dataRequest?.respond(with: data)
        job.remaining -= Int64(data.count); job.position += Int64(data.count)
    }
    private func complete(_ task: URLSessionTask, _ error: Error?) {
        guard let job = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        job.task = nil
        guard error == nil else { finish(job, .network); return }
        guard job.accepted, job.remaining == 0 else { finish(job, .range); return }
        launch(job) // To-end requests also use bounded 512 KiB transfers, never a whole-file Data task.
    }
    private func finish(_ job: Job, _ error: PlaybackFailure? = nil, cancelled: Bool = false) {
        guard jobs.removeValue(forKey: ObjectIdentifier(job.request)) != nil else { return }
        if let task = job.task { transfers.removeValue(forKey: task.taskIdentifier); task.cancel() }
        job.task = nil
        guard !cancelled else { return } // AVFoundation already owns the cancellation terminal event.
        if let error { onFailure(error); job.request.finishLoading(with: error) }
        else { job.request.finishLoading() }
    }
}
