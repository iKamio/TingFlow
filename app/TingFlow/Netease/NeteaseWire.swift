import Foundation

/// Reviewed wire paths from api-enhanced and Kumone. No user-provided hosts or fallback services.
enum NeteaseWire {
    static let webHost = "music.163.com"
    static let interfaceHost = "interface.music.163.com"
    static func url(_ endpoint: NeteaseClient.Endpoint) throws -> URL {
        let suffix = String(endpoint.rawValue.dropFirst(4))
        let host = endpoint.usesEAPI ? interfaceHost : webHost
        let prefix = endpoint.usesPlainWebAPI ? "/api" : (endpoint.usesEAPI ? "/eapi" : "/weapi")
        guard let url = URL(string: "https://\(host)\(prefix)\(suffix)") else { throw NeteaseError.unsafeURL }
        return url
    }
    static func isAPIURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && [webHost, interfaceHost].contains(url.host?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && url.fragment == nil && (url.port == nil || url.port == 443)
    }
    static func header(device: String, csrf: String, cookies: [String: String], date: Date = Date()) -> [String: String] {
        let now = date.timeIntervalSince1970
        var result = ["osver": "Microsoft-Windows-10-Professional-build-19045-64bit", "deviceId": device,
                      "os": "pc", "appver": "3.1.17.204416", "versioncode": "140", "mobilename": "",
                      "buildver": String(Int(now)), "resolution": "1920x1080", "channel": "netease",
                      "requestId": String(format: "%lld_%04d", Int64(now * 1000), Int(now * 1_000_000) % 1000), "__csrf": csrf]
        for name in ["MUSIC_U", "MUSIC_A", "NMTID"] { if let value = cookies[name] { result[name] = value } }
        return result
    }
    static func validate(code: Int, endpoint: NeteaseClient.Endpoint) throws {
        if endpoint == .qrCheck, [800, 801, 802, 803].contains(code) { return }
        if code == 200 { return }
        if code == 301 || code == 302 { throw NeteaseError.signedOut }
        if code == -460 || code == -462 || code == 405 { throw NeteaseError.verification }
        if code == 429 { throw NeteaseError.rateLimited }
        // Never show the raw message/body: it can contain URLs and account details.
        throw NeteaseError.business(code)
    }
    static func responseCookies(_ http: HTTPURLResponse, url: URL) -> [HTTPCookie] {
        var result: [HTTPCookie] = []
        for (key, value) in http.allHeaderFields where String(describing: key).lowercased() == "set-cookie" {
            let combined = String(describing: value)
            // Do not split the comma in Expires=Wed, 21 Oct ...
            let regex = try? NSRegularExpression(pattern: ",(?=\\s*[0-9A-Za-z_!#$%&'*+.^`|~-]+=)")
            let marked = regex?.stringByReplacingMatches(in: combined, range: NSRange(combined.startIndex..., in: combined), withTemplate: "\n") ?? combined
            for line in marked.components(separatedBy: "\n") {
                result += HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url)
            }
        }
        return result
    }
}
