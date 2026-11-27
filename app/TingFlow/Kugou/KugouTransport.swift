import Foundation

protocol KugouTransport {
    func send(_ request: URLRequest) async throws -> Data
}

struct KugouHTTPS: KugouTransport {
    static let maximumBytes = 2 * 1024 * 1024
    static func isAllowed(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              c.percentEncodedPath == c.path,
              let host = c.host, ["login-user.kugou.com", "gateway.kugou.com"].contains(host) else { return false }
        let routes: [String: Set<String>] = ["login-user.kugou.com": ["/v2/qrcode", "/v2/get_userinfo_qrcode"],
            "gateway.kugou.com": ["/v7/get_all_list", "/v4/get_list_all_file_v3"]]
        return routes[host]?.contains(c.path) == true
    }
    static func isAllowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, isAllowed(url), request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil else { return false }
        if url.host == "login-user.kugou.com" {
            return request.httpMethod == "GET" && request.httpBody == nil && request.value(forHTTPHeaderField: "x-router") == nil
        }
        return request.httpMethod == "POST" && (request.httpBody?.count ?? 0) > 0 &&
            (request.httpBody?.count ?? 0) <= 8192 && request.value(forHTTPHeaderField: "x-router") == "cloudlist.service.kugou.com"
    }
    func send(_ request: URLRequest) async throws -> Data {
        guard Self.isAllowed(request) else { throw KugouError.unsafeURL }
        let worker = KugouHTTPWorker()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await worker.start(request)
        }, onCancel: { worker.cancel() })
    }
}

/// One ephemeral session per operation; no shared cookies, credentials, disk cache or redirect.
private final class KugouHTTPWorker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var done = false
    private var cancelled = false
    private var buffer = Data() // accessed only on the serial delegate queue

    func start(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { result in
            lock.lock()
            if cancelled { lock.unlock(); result.resume(throwing: CancellationError()); return }
            continuation = result
            let c = URLSessionConfiguration.ephemeral
            c.httpCookieStorage = nil; c.httpShouldSetCookies = false
            c.urlCredentialStorage = nil; c.urlCache = nil
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 15
            c.connectionProxyDictionary = [:]
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let s = URLSession(configuration: c, delegate: self, delegateQueue: queue)
            session = s
            let task = s.dataTask(with: request)
            lock.unlock(); task.resume()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ value: Result<Data, Error>) {
        lock.lock()
        guard !done, let result = continuation else { lock.unlock(); return }
        done = true; continuation = nil
        let s = session; session = nil
        lock.unlock()
        s?.invalidateAndCancel(); result.resume(with: value)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(KugouError.unsafeURL))
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // System TLS trust evaluation only. Never accept invalid certificates or HTTP authentication.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url, KugouHTTPS.isAllowed(url) else {
            completionHandler(.cancel); finish(.failure(KugouError.unsafeURL)); return
        }
        let error: KugouError?
        if (300...399).contains(http.statusCode) { error = .unsafeURL }
        else if http.statusCode == 429 { error = .rateLimited }
        else if http.statusCode == 401 || http.statusCode == 403 { error = .rejected }
        else if !(200...299).contains(http.statusCode) { error = .network }
        else if response.expectedContentLength > Int64(KugouHTTPS.maximumBytes) { error = .response }
        else if http.value(forHTTPHeaderField: "ssa-code") != nil { error = .verificationRequired }
        else { error = nil }
        if let error { completionHandler(.cancel); finish(.failure(error)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= KugouHTTPS.maximumBytes - buffer.count else { finish(.failure(KugouError.response)); return }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(KugouError.network)) }
        else { finish(.success(buffer)) }
        buffer.removeAll(keepingCapacity: false)
    }
}
