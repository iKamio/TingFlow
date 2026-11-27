import Foundation

protocol KugouServing {
    func qrKey(device: KugouDevice) async throws -> String
    func checkQR(_ key: String, device: KugouDevice) async throws -> KugouQRResult
    func playlists(_ credential: KugouCredential, page: Int, size: Int) async throws -> KugouPage<KugouPlaylist>
    func tracks(_ credential: KugouCredential, listID: String, page: Int, size: Int) async throws -> KugouPage<Song>
}

/// Standard (1005) only. No generic proxy URL, cookie import, cloud writes or playback URL API.
struct KugouClient: KugouServing {
    private let transport: any KugouTransport
    private let now: () -> Date
    init(transport: any KugouTransport = KugouHTTPS(), now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.now = now
    }
    func qrKey(device: KugouDevice) async throws -> String {
        let r = try request(host: "login-user.kugou.com", path: "/v2/qrcode", device: device, kind: .web,
            extra: ["appid": "1014", "type": "1", "plat": "4", "srcappid": "2919",
                "qrcode_txt": "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&"])
        return try KugouMapping.qrKey(await json(r))
    }
    func checkQR(_ key: String, device: KugouDevice) async throws -> KugouQRResult {
        guard KugouMapping.validQRKey(key) else { throw KugouError.response }
        let r = try request(host: "login-user.kugou.com", path: "/v2/get_userinfo_qrcode", device: device, kind: .web,
            extra: ["plat": "4", "srcappid": "2919", "qrcode": key, "dev": device.dev])
        return try KugouMapping.qrResult(await json(r), device: device)
    }
    func playlists(_ c: KugouCredential, page: Int, size: Int) async throws -> KugouPage<KugouPlaylist> {
        try pagination(page, size)
        let body = try KugouCrypto.json([("userid", .number(c.userID)), ("token", .string(c.token)),
            ("total_ver", .number("979")), ("type", .number("2")), ("page", .number(String(page))), ("pagesize", .number(String(size)))])
        let r = try request(host: "gateway.kugou.com", path: "/v7/get_all_list", device: c.device, credential: c,
            extra: ["plat": "1"], body: body, router: "cloudlist.service.kugou.com")
        return try KugouMapping.playlists(await json(r), uid: c.userID)
    }
    func tracks(_ c: KugouCredential, listID: String, page: Int, size: Int) async throws -> KugouPage<Song> {
        try pagination(page, size)
        guard KugouMapping.decimal(listID) != nil else { throw KugouError.response }
        let body = try KugouCrypto.json([("listid", .number(listID)), ("userid", .number(c.userID)),
            ("type", .number("0")), ("page", .number(String(page))), ("pagesize", .number(String(size))),
            ("area_code", .number("1")), ("allplatform", .number("1")), ("show_cover", .number("1")), ("token", .string(c.token))])
        let r = try request(host: "gateway.kugou.com", path: "/v4/get_list_all_file_v3", device: c.device,
            credential: c, body: body, router: "cloudlist.service.kugou.com")
        return try KugouMapping.tracks(await json(r), scope: "kugou:\(c.userID)")
    }
    private func pagination(_ page: Int, _ size: Int) throws {
        guard (1...200).contains(page), (1...300).contains(size) else { throw KugouError.pagination }
    }
    private func timestamp() -> String { String(Int64(now().timeIntervalSince1970.rounded(.down))) }
    // Only the four operations above may construct requests; tests capture them via transport injection.
    private func request(host: String, path: String, device: KugouDevice, credential: KugouCredential? = nil,
                 kind: KugouCrypto.Signature = .android, extra: [String: String] = [:], body: Data = Data(),
                 router: String? = nil, seconds: String? = nil) throws -> URLRequest {
        guard device.isValid, credential?.isValid != false else { throw KugouError.response }
        var p = ["dfid": "-", "mid": device.mid, "uuid": "-", "appid": "1005", "clientver": "20489", "clienttime": seconds ?? timestamp()]
        if let c = credential { p["token"] = c.token; p["userid"] = c.userID }
        p.merge(extra) { _, value in value }
        p["signature"] = KugouCrypto.signature(p, body: body, kind: kind)
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path
        components.queryItems = p.keys.sorted().map { URLQueryItem(name: $0, value: p[$0]) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, KugouHTTPS.isAllowed(url) else { throw KugouError.unsafeURL }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        r.httpMethod = body.isEmpty ? "GET" : "POST"; r.httpShouldHandleCookies = false
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi", forHTTPHeaderField: "User-Agent")
        r.setValue("-", forHTTPHeaderField: "dfid"); r.setValue(device.mid, forHTTPHeaderField: "mid")
        r.setValue(p["clienttime"], forHTTPHeaderField: "clienttime")
        r.setValue("1", forHTTPHeaderField: "kg-rc"); r.setValue("5d816a0", forHTTPHeaderField: "kg-thash")
        r.setValue("1", forHTTPHeaderField: "kg-rec"); r.setValue("B9EDA08A64250DEFFBCADDEE00F8F25F", forHTTPHeaderField: "kg-rf")
        if let router {
            guard router == "cloudlist.service.kugou.com" else { throw KugouError.unsafeURL }
            r.setValue(router, forHTTPHeaderField: "x-router")
        }
        if !body.isEmpty { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let bytes: Data
        do { bytes = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as KugouError { throw error }
        catch { throw KugouError.network }
        try Task.checkCancellation()
        guard bytes.count <= KugouHTTPS.maximumBytes,
              let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { throw KugouError.response }
        if let value = root["status"] {
            guard let status = KugouMapping.int(value) else { throw KugouError.response }
            guard status == 1 else { throw KugouError.rejected }
        }
        if let value = root["error_code"] {
            guard let code = KugouMapping.int(value) else { throw KugouError.response }
            guard code == 0 else { throw KugouError.rejected }
        }
        guard root["status"] != nil || root["error_code"] != nil else { throw KugouError.response }
        return root
    }
}
