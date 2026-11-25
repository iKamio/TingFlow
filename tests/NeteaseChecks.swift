// macOS offline executable; no network, Keychain read or real login.
// Build command is documented in Netease/IMPLEMENTATION.md.
import Foundation

@main struct NeteaseChecks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), "FAIL: \(label)")
            count += 1
        }
        func rejects(_ expected: NeteaseError, _ label: String, _ work: () throws -> Void) {
            do { try work(); preconditionFailure("FAIL: \(label)") }
            catch { expect(error as? NeteaseError == expected, label) }
        }
        let sealed = try NeteaseCrypto.seal([:], secret: "0123456789abcdef")
        expect(sealed["params"] == "kxBNj/l03n7aQ/q0EdABwtOsIYuwYGkESNTUk4QvWCg=", "AES CBC PKCS7 double encryption")
        expect(sealed["encSecKey"] == "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52", "raw RSA zero padding and reversed secret")
        let form = String(decoding: NeteaseCrypto.form(["params": "a+b/c=", "encSecKey": "00"]), as: UTF8.self)
        expect(form == "encSecKey=00&params=a%2Bb%2Fc%3D", "form encoding prevents base64 corruption")
        rejects(.crypto, "invalid secret length") { _ = try NeteaseCrypto.seal([:], secret: "x") }
        let randomA = try NeteaseCrypto.seal([:])
        let randomB = try NeteaseCrypto.seal([:])
        expect(randomA != randomB, "fresh random request key")

        expect(NeteaseMapping.id("123") == "123", "string ID")
        expect(NeteaseMapping.id(NSNumber(value: 123)) == "123", "numeric ID")
        expect(NeteaseMapping.id(true) == nil, "reject boolean ID")
        expect(NeteaseMapping.id("-1") == nil, "reject negative ID")
        expect(NeteaseMapping.id("12.3") == nil, "reject decimal ID")
        expect(NeteaseMapping.id("123\nCookie: x") == nil, "reject injection ID")
        let identity = try NeteaseMapping.identity(["account": ["id": 7], "profile": ["userId": 7, "nickname": "Fixture"]])
        expect(identity.id == "7" && identity.name == "Fixture", "canonical identity")
        rejects(.identity, "mismatched identity") {
            _ = try NeteaseMapping.identity(["account": ["id": 7], "profile": ["userId": 8]])
        }
        rejects(.identity, "cookie is not proof of login") { _ = try NeteaseMapping.identity(["code": 200]) }

        let details: [[String: Any]] = [
            ["id": 2, "name": "B", "dt": 2000, "ar": [["name": "Artist B"]]],
            ["id": 1, "name": "A", "dt": 1000, "ar": [["name": "Artist A"]]]
        ]
        let songs = NeteaseMapping.orderedSongs(ids: ["1", "2", "1", "3"], details: details, scope: "netease:7")
        expect(songs.map(\.platformID) == ["1", "2", "1", "3"], "track order and duplicates preserved")
        expect(songs.map(\.title) == ["A", "B", "A", "暂不可用的歌曲"], "missing detail retains its index")
        expect(songs[0].duration == 1, "milliseconds to seconds")
        expect(songs.allSatisfy { $0.accountScope == "netease:7" }, "account-scoped metadata")
        let encoded = String(decoding: try JSONEncoder().encode(songs), as: UTF8.self)
        expect(!encoded.contains("MUSIC_U") && !encoded.contains("Cookie") && !encoded.contains("encSecKey"), "no credentials in Song")
        let ids = (1...1201).map(String.init)
        let batches = stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
        expect(batches.map(\.count) == [500, 500, 201] && batches.flatMap { $0 } == ids, "all-track batch boundary")

        expect(NeteaseClient.isAPIURL(URL(string: "https://music.163.com/weapi/test")!), "exact API host")
        for raw in ["http://music.163.com/", "https://music.163.com.evil.invalid/", "https://interface.music.163.com.evil.invalid/", "https://u@music.163.com/", "https://music.163.com:444/"] {
            expect(!NeteaseClient.isAPIURL(URL(string: raw)!), "reject unsafe API origin")
        }
        expect(NeteaseMapping.mediaURL("http://m1.music.126.net/a.mp3?x=1")?.absoluteString == "https://m1.music.126.net/a.mp3?x=1", "official CDN HTTPS upgrade preserves resource")
        expect(NeteaseMapping.artworkURL("http://p1.music.126.net/a.jpg")?.scheme == "https", "artwork HTTPS upgrade")
        expect(NeteaseMapping.artworkURL("https://p1.music.126.net/a.jpg?token=fixture") == nil, "no signed artwork in metadata")
        for raw in ["http://music.163.com/a.mp3", "http://m1.music.126.net:81/a.mp3", "https://music.126.net.evil.invalid/a", "https://127.0.0.1/a", "https://u:p@m1.music.126.net/a"] {
            expect(NeteaseMapping.mediaURL(raw) == nil, "reject unsafe media URL")
        }
        var row: [String: Any] = ["id": 1, "code": 200, "url": "https://m1.music.126.net/fixture.mp3", "type": "mp3", "br": 128000, "freeTrialInfo": NSNull()]
        var resource = try NeteaseMapping.playback(["data": [row]], songID: "1")
        expect(!resource.isPreview && resource.headers.isEmpty, "full track no credential forwarding")
        row["freeTrialInfo"] = ["start": 0, "end": 30]
        resource = try NeteaseMapping.playback(["data": [row]], songID: "1")
        expect(resource.isPreview && resource.displayQuality.contains("平台试听") && resource.displayQuality.contains("128 kbps"), "explicit trial labeling with actual quality")
        row["url"] = NSNull()
        rejects(.unavailable, "null playback URL is permission failure") { _ = try NeteaseMapping.playback(["data": [row]], songID: "1") }
        row["url"] = "https://m1.music.126.net/fixture.mp3"
        row["isDRM"] = true
        rejects(.drmRestricted, "no DRM bypass") { _ = try NeteaseMapping.playback(["data": [row]], songID: "1") }
        rejects(.response, "no substitution with another song") { _ = try NeteaseMapping.playback(["data": [row]], songID: "2") }
        expect(NeteaseError.message(NSError(domain: "secret-token-fixture", code: 1)) == "操作未完成，请稍后重试。", "unknown error sanitized")
        let eapi = try NeteaseCrypto.sealEAPI(apiPath: "/api/user/playlist", object: ["uid": 7, "includeVideo": true, "limit": 100, "offset": 0])
        expect(eapi["params"] == "B794DDEDF8B618087E534DC803FDE82C5E0023679BCAEF6A43314E846D0A2C02B37620ED14BE3D9C609F27E770602BDBC7CB0B0AF5847289143285083C0A099DD66F39FCD9FAAF47641A14B2476BAC4DEB568119BBC24D2ADAA2B982935F8FF9F1C98ED4270C3969BE2BFA22AA293D36CEAD95607413B15008F2397BCA974F986AA3B102FBE7296AB0DB9EA5C46AD12B", "EAPI independent AES/MD5 vector")
        let header = NeteaseWire.header(device: "fixture-device", csrf: "fixture-csrf", cookies: ["MUSIC_U": "fixture-user", "MUSIC_A": "fixture-anonymous", "NMTID": "fixture-nmtid", "WNMCID": "do-not-forward"], date: Date(timeIntervalSince1970: 1700000000))
        expect(header["MUSIC_U"] == "fixture-user" && header["MUSIC_A"] == "fixture-anonymous" && header["NMTID"] == "fixture-nmtid", "EAPI includes upstream allowlisted session fields")
        expect(header["WNMCID"] == nil && header["deviceId"] == "fixture-device", "unrelated browser cookies not copied to EAPI header")
        let keyURL = try NeteaseWire.url(.qrKey), identityURL = try NeteaseWire.url(.identity)
        expect(keyURL.host == "interface.music.163.com", "QR EAPI host")
        expect(identityURL.path == "/eapi/nuser/account/get", "canonical identity route")
        for code in [800, 801, 802, 803] { try NeteaseWire.validate(code: code, endpoint: .qrCheck) }
        rejects(.verification, "explicit risk check") { try NeteaseWire.validate(code: -460, endpoint: .identity) }
        rejects(.business(400), "fixed code not raw server body") { try NeteaseWire.validate(code: 400, endpoint: .dailySongs) }
        let noHistory = try NeteaseMapping.dailySongs(["data": NSNull()], scope: "netease:7")
        expect(noHistory.isEmpty, "new account no daily history")
        print("PASS: \(count) Netease offline checks (no endpoint/login assertion)")
    }
}
