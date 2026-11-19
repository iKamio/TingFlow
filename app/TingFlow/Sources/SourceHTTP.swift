import Foundation

struct SourceHTTPReply {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    func json() throws -> [String: Any] {
        let content = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard !["application/octet-stream", "audio/", "video/", "image/", "multipart/"].contains(where: { content.hasPrefix($0) }),
              let text = String(data: data, encoding: .utf8) else { throw SourceFailure.unsupported }
        let body = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? text
        return ["statusCode": statusCode, "statusMessage": HTTPURLResponse.localizedString(forStatusCode: statusCode),
                "headers": headers, "body": body]
    }
}

/// Native-only transport. No instance is ever passed to JavaScript.
final class SourceHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let id: String
        let task: URLSessionDataTask
        let limit: Int
        let completion: (Result<SourceHTTPReply, Error>) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        init(_ id: String, _ task: URLSessionDataTask, _ limit: Int, _ completion: @escaping (Result<SourceHTTPReply, Error>) -> Void) {
            self.id = id; self.task = task; self.limit = limit; self.completion = completion
        }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var total = 0
    private var closed = false
    private var session: URLSession!
    let budget: Int
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 4
        return c
    }
    init(budget: Int = 2 * 1024 * 1024) {
        self.budget = budget
        super.init()
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: q)
    }
    static func makeRequest(_ raw: String, allowed: [String], options: [String: Any]) throws -> URLRequest {
        let url = try SourceURLPolicy.url(raw, allowed: allowed)
        if options["formData"] != nil || options["binary"] != nil { throw SourceFailure.unsupported }
        let method = (options["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else { throw SourceFailure.unsupported }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        let timeout = (options["timeout"] as? NSNumber)?.doubleValue ?? 13000
        guard timeout.isFinite, timeout > 0 else { throw SourceFailure.unsupported }
        request.timeoutInterval = min(60, max(0.1, timeout / 1000))
        if let input = options["headers"] {
            guard let headers = input as? [String: String], headers.count <= 32,
                  headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 8192 else { throw SourceFailure.unsupported }
            for (name, value) in headers {
                guard !name.isEmpty, name.utf8.count <= 128,
                      name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      !value.contains("\r"), !value.contains("\n"),
                      !["cookie", "cookie2", "host", "content-length", "connection", "proxy-authorization"].contains(name.lowercased()) else { throw SourceFailure.unsupported }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let body = options["body"], !(body is NSNull) {
            guard let text = body as? String else { throw SourceFailure.unsupported }
            request.httpBody = Data(text.utf8)
        } else if let value = options["form"] {
            guard let form = value as? [String: Any], form.count <= 128 else { throw SourceFailure.unsupported }
            var parts: [String] = []
            for key in form.keys.sorted() {
                let v = form[key]!
                guard v is String || v is NSNumber || v is NSNull else { throw SourceFailure.unsupported }
                parts.append("\(encode(key))=\(encode(v is NSNull ? "" : String(describing: v)))")
            }
            request.httpBody = Data(parts.joined(separator: "&").utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        guard (request.httpBody?.count ?? 0) <= 1024 * 1024 else { throw SourceFailure.tooLarge }
        return request
    }
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
    @discardableResult func request(_ raw: String, allowed: [String], options: [String: Any] = [:], limit: Int = 2 * 1024 * 1024,
                                    completion: @escaping (Result<SourceHTTPReply, Error>) -> Void) throws -> String {
        let request = try Self.makeRequest(raw, allowed: allowed, options: options)
        lock.lock()
        guard !closed, pending.count < 4 else { lock.unlock(); throw SourceFailure.busy }
        let task = session.dataTask(with: request), id = UUID().uuidString
        pending[task.taskIdentifier] = Pending(id, task, min(limit, budget), completion)
        lock.unlock(); task.resume(); return id
    }
    func resetBudget() { lock.lock(); total = 0; lock.unlock() }
    func cancel(_ id: String) {
        lock.lock(); let item = pending.values.first { $0.id == id }; lock.unlock()
        if let item { finish(item.task, .failure(SourceFailure.cancelled), cancel: true) }
    }
    func cancelAll() {
        lock.lock(); let items = Array(pending.values); pending.removeAll(); lock.unlock()
        for item in items { item.task.cancel(); item.completion(.failure(SourceFailure.cancelled)) }
    }
    func close() {
        lock.lock(); closed = true; lock.unlock()
        cancelAll(); session.invalidateAndCancel()
    }
    private func finish(_ task: URLSessionTask, _ result: Result<SourceHTTPReply, Error>, cancel: Bool = false) {
        lock.lock(); let item = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if cancel { task.cancel() }
        item?.completion(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(task, .failure(SourceFailure.redirect), cancel: true)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(dataTask, .failure(SourceFailure.network)); return
        }
        lock.lock()
        let item = pending[dataTask.taskIdentifier]
        let oversized = response.expectedContentLength > Int64(item?.limit ?? budget)
        item?.response = response
        lock.unlock()
        if oversized { completionHandler(.cancel); finish(dataTask, .failure(SourceFailure.tooLarge)) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        total += data.count
        let oversized = total > budget || item.data.count + data.count > item.limit
        if !oversized { item.data.append(data) }
        lock.unlock()
        if oversized { finish(dataTask, .failure(SourceFailure.tooLarge), cancel: true) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending[task.taskIdentifier]; lock.unlock()
        guard let item else { return }
        if error != nil { finish(task, .failure(SourceFailure.network)); return }
        guard let response = item.response else { finish(task, .failure(SourceFailure.network)); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            // Even source-private response cookies never enter JS or a shared cookie jar.
            if name.lowercased() != "set-cookie" && name.lowercased() != "set-cookie2" { headers[name] = String(describing: value) }
        }
        finish(task, .success(SourceHTTPReply(data: item.data, statusCode: response.statusCode, headers: headers)))
    }
    static func download(_ raw: String) async throws -> Data {
        let url = try SourceURLPolicy.url(raw)
        let transport = SourceHTTP(budget: 1024 * 1024)
        defer { transport.close() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: SourceFailure.cancelled); return }
                do {
                    try transport.request(url.absoluteString, allowed: [try SourceURLPolicy.host(url.host ?? "")], limit: 1024 * 1024) { result in
                        switch result {
                        case .success(let reply):
                            if (200..<300).contains(reply.statusCode) { continuation.resume(returning: reply.data) }
                            else { continuation.resume(throwing: SourceFailure.network) }
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { transport.close() })
    }
}
