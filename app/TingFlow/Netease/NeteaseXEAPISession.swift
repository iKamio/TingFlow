import Foundation

private final class XEAPIRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One authenticated client's memory-only protocol state. No anti-cheat service,
/// source substitution, device rotation, session-key persistence or denial retries.
@MainActor final class NeteaseXEAPISession {
    private let session: URLSession
    private let device: String
    private var invalidated = false
    private struct KeyResult {
        let state: NeteaseXEAPI.PublicKeyState
        let httpStatus: Int
        let businessCode: Int
    }
    private struct KeyFailure: Error {
        let underlying: Error
        let httpStatus: Int?
        let businessCode: Int?
    }
    private var cachedKey: (KeyResult, Date)?
    private var keyTask: Task<KeyResult, Error>?
    private var keyTicket = UUID()
    private static let agent = "NeteaseMusic/9.1.65.240429090313(9001065);Dalvik/2.1.0 (Linux; U; Android 12; HBN-AL00 Build/cd737a2.0)"

    init(configuration: URLSessionConfiguration, device: String) {
        self.device = device
        session = URLSession(configuration: configuration, delegate: XEAPIRedirectBlocker(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func invalidate() {
        invalidated = true; keyTask?.cancel(); keyTask = nil; keyTicket = UUID()
        cachedKey = nil; session.invalidateAndCancel()
    }
    func playback(_ payload: [String: Any], cookies: [String: String],
                  report: (NeteasePlaybackDiagnostic?) -> Void) async throws -> (object: [String: Any], response: HTTPURLResponse) {
        var diagnostic: NeteasePlaybackDiagnostic? = NeteasePlaybackDiagnostic(v1: true, level: payload["level"] as? String)
        diagnostic?.negotiatingKey = true
        // A cancelled caller must not overwrite a newer explicit playback mode.
        defer { if !Task.isCancelled && !invalidated { report(diagnostic) } }
        do {
            try ensureActive()
            let negotiated: KeyResult
            do { negotiated = try await publicKey() }
            catch let failure as KeyFailure {
                diagnostic?.keyHTTPStatus = failure.httpStatus
                diagnostic?.keyBusinessCode = failure.businessCode
                throw failure.underlying
            }
            try ensureActive()
            diagnostic?.keyHTTPStatus = negotiated.httpStatus
            diagnostic?.keyBusinessCode = negotiated.businessCode
            diagnostic?.negotiatingKey = false
            let state = negotiated.state
            let url = try NeteaseWire.url(.playbackV1)
            let fields: [String: String]
            do { fields = try NeteaseXEAPI.seal(apiPath: "/api/song/enhance/player/url/v1", payload: payload, state: state) }
            catch { throw NeteaseError.response }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "POST"; request.httpShouldHandleCookies = false
            request.httpBody = NeteaseCrypto.form(fields)
            request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/octet-stream, application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            request.setValue("ENCRYPTED", forHTTPHeaderField: "X-Client-Enc-State")
            request.setValue("true", forHTTPHeaderField: "x-aeapi")
            let build = String(Int(Date().timeIntervalSince1970))
            var jar = ["os": "android", "osver": "16", "appver": "9.1.65", "buildver": build,
                       "deviceId": device, "sDeviceId": device]
            for name in ["MUSIC_U", "MUSIC_A", "__csrf", "NMTID"] { if let value = cookies[name] { jar[name] = value } }
            for (name, value) in ["x-deviceid": device, "x-sdeviceid": device, "x-os": "android", "x-osver": "16", "x-appver": "9.1.65", "x-buildver": build] {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let value = cookies["MUSIC_U"] { request.setValue(value, forHTTPHeaderField: "x-music-u") }
            request.setValue(jar.keys.sorted().map { "\($0)=\(jar[$0]!)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            let (data, http) = try await send(request, maximum: 2_000_000)
            diagnostic?.httpStatus = http.statusCode
            try validateHTTP(http.statusCode)
            let object: [String: Any]
            do { object = try NeteaseXEAPI.response(data) } catch { throw NeteaseError.response }
            guard let code = object["code"] as? Int else { throw NeteaseError.response }
            diagnostic?.businessCode = code
            diagnostic?.mediaCodes = Array((object["data"] as? [[String: Any]] ?? []).prefix(8).compactMap { $0["code"] as? Int })
            try NeteaseWire.validate(code: code, endpoint: .playbackV1)
            return (object, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NeteaseError { throw error }
        catch {
            if Task.isCancelled || invalidated { throw CancellationError() }
            if NeteaseAudioPolicy.isTransientTransport(error) { throw NeteaseError.transientNetwork }
            throw NeteaseError.network
        }
    }
    private func ensureActive() throws {
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
    }
    private func publicKey() async throws -> KeyResult {
        if let (value, expires) = cachedKey, expires > Date() { return value }
        if let keyTask { let value = try await keyTask.value; try ensureActive(); return value }
        let ticket = UUID(); keyTicket = ticket
        let task = Task { @MainActor in try await self.fetchPublicKey() }
        keyTask = task
        do {
            let value = try await task.value
            guard !invalidated, keyTicket == ticket else { throw CancellationError() }
            cachedKey = (value, Date().addingTimeInterval(900)); keyTask = nil
            try ensureActive()
            return value
        } catch {
            if keyTicket == ticket { keyTask = nil }
            throw error
        }
    }
    private func fetchPublicKey() async throws -> KeyResult {
        var keyHTTPStatus: Int?
        var keyBusinessCode: Int?
        do {
            try ensureActive()
            let fields: [String: String]
            do { fields = try NeteaseXEAPI.registration(device: device) } catch { throw NeteaseError.response }
            guard let nonce = fields["nonce"] else { throw NeteaseError.response }
            var request = URLRequest(url: NeteaseWire.xeapiKeyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"; request.httpShouldHandleCookies = false
            request.httpBody = NeteaseCrypto.form(fields)
            request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("NeteaseMusic/9.5.61.260802021928(9005061);Dalvik/2.1.0 (Linux; U; Android 12; HBN-AL00 Build/cd737a2.0)", forHTTPHeaderField: "User-Agent")
            // Negotiation is anonymous: never forward MUSIC_U, x-music-u, CSRF or a user ID.
            request.setValue("deviceId=\(device)", forHTTPHeaderField: "Cookie")
            let (data, http) = try await send(request, maximum: 128_000)
            keyHTTPStatus = http.statusCode
            try validateHTTP(http.statusCode)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["code"] as? Int else { throw NeteaseError.response }
            keyBusinessCode = code
            try NeteaseWire.validate(code: code, endpoint: .playbackV1)
            let state: NeteaseXEAPI.PublicKeyState
            do { state = try NeteaseXEAPI.publicKey(from: data, nonce: nonce) }
            catch { throw NeteaseError.response }
            return KeyResult(state: state, httpStatus: http.statusCode, businessCode: code)
        } catch is CancellationError { throw CancellationError() }
        catch { throw KeyFailure(underlying: error, httpStatus: keyHTTPStatus, businessCode: keyBusinessCode) }
    }
    private func validateHTTP(_ status: Int) throws {
        if status == 401 { throw NeteaseError.signedOut }
        if status == 429 { throw NeteaseError.rateLimited }
        guard (200..<300).contains(status) else { throw NeteaseError.http(status) }
    }
    private func send(_ request: URLRequest, maximum: Int) async throws -> (Data, HTTPURLResponse) {
        try ensureActive()
        let (bytes, response) = try await session.bytes(for: request)
        try ensureActive()
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw NeteaseError.unsafeURL }
        guard response.expectedContentLength <= Int64(maximum) else { throw NeteaseError.response }
        var data = Data(); data.reserveCapacity(min(maximum, 64_000))
        for try await byte in bytes {
            guard data.count < maximum else { throw NeteaseError.response }
            data.append(byte)
        }
        try ensureActive()
        return (data, http)
    }
}
