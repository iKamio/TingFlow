import Foundation
import CryptoKit
import CommonCrypto

/// Independent synthetic peer. No sockets, external URLs, real songs or accounts.
enum NeteaseXEAPIServerFixture {
    private static let privateKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
    private static let staticKey = hex("ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84")
    private static let signKey = SymmetricKey(data: Data("mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==".utf8))
    static let sharedSecret = "fixture-ephemeral-sk"
    private static let lock = NSLock()
    private static var keyCalls = 0
    private static var badKeySignature = false
    static func keyRequestCount() -> Int { lock.lock(); defer { lock.unlock() }; return keyCalls }
    static func reset(badSignature: Bool = false) { lock.lock(); defer { lock.unlock() }; keyCalls = 0; badKeySignature = badSignature }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        return data
    }
    private static func parseForm(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for item in text.split(separator: "&") {
            let p = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard p.count == 2, let key = String(p[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(p[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { continue }
            fields[key] = value
        }
        return fields
    }
    static func keyResponse(_ request: URLRequest) throws -> Data {
        lock.lock(); keyCalls += 1; let corrupt = badKeySignature; lock.unlock()
        precondition(request.url == NeteaseWire.xeapiKeyURL && request.httpMethod == "POST")
        let fields = parseForm(body(request))
        precondition(fields["os"] == "android" && fields["uid"] == "" && fields["currentKeyVersion"] == "")
        precondition(fields["deviceId"] == String(repeating: "A", count: 52))
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        precondition(cookie == "deviceId=" + String(repeating: "A", count: 52))
        precondition(request.value(forHTTPHeaderField: "x-music-u") == nil && !cookie.contains("synthetic-quality"))
        let nonce = fields["nonce"]!, timestamp = fields["timestamp"]!
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data((timestamp + nonce).utf8), using: signKey)).base64EncodedString()
        precondition(fields["signature"] == expected, "independent request HMAC")
        let keyBody: [String: Any] = ["publicKey": privateKey.publicKey.rawRepresentation.base64EncodedString(), "version": "fixture-v1", "sk": sharedSecret]
        let encrypted = try aes(try JSONSerialization.data(withJSONObject: keyBody), key: staticKey, encrypt: true).base64EncodedString()
        let serverTime = "1795584000000"
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data((serverTime + nonce).utf8), using: signKey)).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: ["code": 200, "data": ["encryptedData": encrypted, "timestamp": serverTime, "signature": corrupt ? "invalid" : signature]])
    }
    static func openPayload(_ request: URLRequest, expectedMusicU: String? = "synthetic-quality-fixture") -> [String: Any] {
        do {
            precondition(request.url?.host == "interface3.music.163.com" && request.url?.path == "/xeapi/song/enhance/player/url/v1")
            precondition(request.httpMethod == "POST" && !request.httpShouldHandleCookies)
            precondition(request.value(forHTTPHeaderField: "X-Client-Enc-State") == "ENCRYPTED")
            precondition(request.value(forHTTPHeaderField: "x-aeapi") == "true" && request.value(forHTTPHeaderField: "x-os") == "android")
            var cookie: [String: String] = [:]
            for part in (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                precondition(pair.count == 2 && cookie[String(pair[0])] == nil, "unambiguous synthetic Cookie")
                cookie[String(pair[0])] = String(pair[1])
            }
            precondition(cookie["MUSIC_U"] == expectedMusicU && request.value(forHTTPHeaderField: "x-music-u") == expectedMusicU)
            let pairs = ["deviceId": "x-deviceid", "sDeviceId": "x-sdeviceid", "os": "x-os",
                         "osver": "x-osver", "appver": "x-appver", "buildver": "x-buildver"]
            for (name, header) in pairs {
                precondition(cookie[name]?.isEmpty == false && cookie[name] == request.value(forHTTPHeaderField: header), "XEAPI Cookie/header coherence")
            }
            precondition(cookie["deviceId"] == String(repeating: "A", count: 52) && cookie["sDeviceId"] == cookie["deviceId"])
            let allowed = Set(["deviceId", "sDeviceId", "os", "osver", "appver", "buildver", "MUSIC_U", "MUSIC_A", "__csrf", "NMTID"])
            precondition(Set(cookie.keys).isSubset(of: allowed), "XEAPI Cookie name allowlist")
            let fields = parseForm(body(request)); precondition(Set(fields.keys) == ["C", "S", "R"])
            let s = Data(base64Encoded: fields["S"]!)!
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(s.prefix(32)))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0, count: 32), sharedInfo: Data(s.prefix(32)), outputByteCount: 16)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: s[32..<44]), ciphertext: s[44..<(s.count - 16)], tag: s.suffix(16))
            let plain = try AES.GCM.open(box, using: key)
            let p = String(decoding: plain, as: UTF8.self).components(separatedBy: "|")
            precondition(p.count == 3 && p[1] == "android" && p[2] == sharedSecret)
            let dynamic = Data(base64Encoded: p[0])!
            let r = try aes(Data(base64Encoded: fields["R"]!)!, key: staticKey, encrypt: false)
            precondition(String(decoding: r, as: UTF8.self) == "fixture-v1|")
            var c = fields["C"]!.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            c += String(repeating: "=", count: (4 - c.count % 4) % 4)
            let mid = try aes(Data(base64Encoded: c)!, key: dynamic, encrypt: false)
            let mask = Array(mid.prefix(16)), rotated = Array(mid.dropFirst(16))
            precondition(!rotated.isEmpty)
            let rot = Int(mask[0] & 15) % rotated.count
            let xored = Array(rotated.suffix(rot)) + Array(rotated.prefix(rotated.count - rot))
            let inner = Data(xored.enumerated().map { $0.element ^ mask[$0.offset & 15] })
            let envelope = try JSONSerialization.jsonObject(with: aes(inner, key: staticKey, encrypt: false)) as! [String: Any]
            precondition(envelope["queryString"] as? String == "e_r=true")
            let payload = parseForm(Data((envelope["content"] as! String).utf8))
            return payload
        } catch { preconditionFailure("Synthetic XEAPI peer could not validate request") }
    }
    static func encryptedResponse(_ object: [String: Any]) -> Data {
        try! aes(JSONSerialization.data(withJSONObject: object), key: Data("e82ckenh8dichen8".utf8), encrypt: true)
    }
    private static func aes(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        var out = [UInt8](repeating: 0, count: data.count + 16), length = 0
        let cap = out.count
        let status = key.withUnsafeBytes { k in data.withUnsafeBytes { b in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), k.baseAddress, key.count, nil, b.baseAddress, data.count, &out, cap, &length)
        } }
        guard status == kCCSuccess else { throw URLError(.cannotDecodeContentData) }
        return Data(out.prefix(length))
    }
    private static func hex(_ text: String) -> Data { let a = Array(text); return Data(stride(from: 0, to: a.count, by: 2).map { UInt8(String(a[$0...$0+1]), radix: 16)! }) }
}
