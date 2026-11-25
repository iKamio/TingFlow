// macOS offline executable; compile with NeteaseXEAPI.swift and link zlib:
// swiftc -O app/TingFlow/Netease/NeteaseXEAPI.swift tests/NeteaseXEAPIChecks.swift -lz -o /tmp/netease-xeapi-checks
// (Run from the source root: /tmp/netease-xeapi-checks)
// No network, account, Keychain, or locally available iOS SDK is required.
import Foundation

@main struct NeteaseXEAPIChecks {
    static func main() throws {
        let fixtureURL = URL(fileURLWithPath: "tests/fixtures/NeteaseXEAPIVectors.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let inputs = fixture["inputs"] as! [String: Any]
        let expected = fixture["expected"] as! [String: Any]
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), "FAIL: \(name)")
            count += 1
        }
        func rejects(_ error: NeteaseXEAPI.Failure, _ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("FAIL: \(name)") }
            catch let actual as NeteaseXEAPI.Failure { expect(actual == error, name) }
            catch { preconditionFailure("FAIL: \(name): non-sanitized error type") }
        }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
        func decode(_ text: String) -> Data { Data(base64Encoded: text)! }
        func hex(_ text: String) -> Data {
            let bytes = Array(text)
            precondition(bytes.count % 2 == 0)
            return Data(stride(from: 0, to: bytes.count, by: 2).map {
                UInt8(String(bytes[$0...($0 + 1)]), radix: 16)!
            })
        }

        let peer = decode(expected["peerPublic"] as! String)
        let state = NeteaseXEAPI.PublicKeyState(publicKey: peer,
            version: inputs["version"] as! String, sk: inputs["sk"] as! String)
        let payload = inputs["payload"] as! [String: Any]
        let request = try NeteaseXEAPI.buildPlaintext(payload)
        expect(String(decoding: request, as: UTF8.self) == expected["requestPlaintext"] as! String,
               "URLSearchParams form bytes, JS coercion and e_r override removal")

        let entropy = NeteaseXEAPI.Entropy(dynamicKey: hex(inputs["dynamicKey"] as! String),
            mask: hex(inputs["mask"] as! String),
            ephemeralPrivateKey: hex(inputs["ephemeralPrivate"] as! String),
            nonce: hex(inputs["gcmNonce"] as! String))
        let sealed = try NeteaseXEAPI.seal(apiPath: "/api/fixture", payload: payload, state: state, entropy: entropy)
        expect(sealed["C"] == expected["C"] as? String, "C AES/static/mask rotation/base64url vector")
        expect(sealed["S"] == expected["S"] as? String, "S X25519/HKDF/GCM layout vector")
        expect(sealed["R"] == expected["R"] as? String, "R version AES/static vector")
        expect(sealed.count == 3, "sealed field set is C,S,R only")

        let registration = try NeteaseXEAPI.registration(device: inputs["device"] as! String,
            timestamp: inputs["timestamp"] as? String, nonce: inputs["nonce"] as? String)
        let expectedRegistration = expected["registration"] as! [String: String]
        expect(registration == expectedRegistration, "deterministic registration and ASCII-literal HMAC vector")
        expect(registration["nonce"] == inputs["nonce"] as? String, "registration exposes response-verification nonce")
        rejects(.invalidInput, "reject registration line breaks") {
            _ = try NeteaseXEAPI.registration(device: "fixture\nCookie: x", timestamp: "1", nonce: "0123456789012345")
        }

        let signed = try json(expected["signedKeyResponse"]!)
        let parsed = try NeteaseXEAPI.publicKey(from: signed, nonce: inputs["nonce"] as! String)
        expect(parsed.publicKey == peer && parsed.version == state.version && parsed.sk == state.sk,
               "verify signature before decrypting and parse validated public key")
        var tampered = expected["signedKeyResponse"] as! [String: Any]
        var tamperedBody = tampered["data"] as! [String: Any]
        tamperedBody["signature"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        tampered["data"] = tamperedBody
        rejects(.invalidSignature, "reject signature mismatch") {
            _ = try NeteaseXEAPI.publicKey(from: json(tampered), nonce: inputs["nonce"] as! String)
        }
        var badCode = expected["signedKeyResponse"] as! [String: Any]
        badCode["code"] = 403
        rejects(.invalidResponse, "reject key registration business error") {
            _ = try NeteaseXEAPI.publicKey(from: json(badCode), nonce: inputs["nonce"] as! String)
        }
        rejects(.invalidKey, "reject malformed raw public-key size") {
            _ = try NeteaseXEAPI.seal(apiPath: "/api/fixture", payload: [:],
                state: .init(publicKey: Data([1]), version: "v", sk: "sk"), entropy: entropy)
        }
        rejects(.invalidInput, "reject unsafe API path") {
            _ = try NeteaseXEAPI.seal(apiPath: "/api/../secret", payload: [:], state: state, entropy: entropy)
        }

        let plainResponse = try NeteaseXEAPI.response(decode(expected["encryptedResponse"] as! String))
        expect((plainResponse["code"] as? Int) == 200, "decrypt AES-128-ECB JSON response")
        let plainData = plainResponse["data"] as! [String: Any]
        expect(plainData["note"] as? String == "synthetic fixture", "decrypted response contents")
        let gzipResponse = try NeteaseXEAPI.response(decode(expected["encryptedGzipResponse"] as! String))
        expect((gzipResponse["data"] as? [String: Any])?["gzip"] as? String == "synthetic fixture",
               "decrypt and bounded-gunzip encrypted response")
        let business = try NeteaseXEAPI.response(Data("{\"code\":400}".utf8))
        expect((business["code"] as? Int) == 400, "preserve plain JSON business errors")
        rejects(.cryptography, "no plaintext fallback after corrupt ciphertext") {
            _ = try NeteaseXEAPI.response(Data(repeating: 0, count: 16))
        }
        rejects(.invalidInput, "reject invalid signed-response nonce") {
            _ = try NeteaseXEAPI.publicKey(from: signed, nonce: "short")
        }
        rejects(.sizeLimit, "reject gzip output larger than cap") {
            _ = try NeteaseXEAPI.response(decode(expected["encryptedOversizeGzipResponse"] as! String))
        }
        rejects(.sizeLimit, "reject oversized wire response before parsing") {
            _ = try NeteaseXEAPI.response(Data(repeating: 0, count: NeteaseXEAPI.maximumResponseBytes + 17))
        }
        rejects(.invalidResponse, "reject empty response") { _ = try NeteaseXEAPI.response(Data()) }
        rejects(.invalidResponse, "reject non-object plain JSON") { _ = try NeteaseXEAPI.response(Data("[]".utf8)) }
        rejects(.invalidKey, "reject all-zero public key") {
            _ = try NeteaseXEAPI.seal(apiPath: "/api/fixture", payload: [:],
                state: .init(publicKey: Data(repeating: 0, count: 32), version: "v", sk: "sk"), entropy: entropy)
        }
        let freshA = try NeteaseXEAPI.seal(apiPath: "/api/fixture", payload: payload, state: state)
        let freshB = try NeteaseXEAPI.seal(apiPath: "/api/fixture", payload: payload, state: state)
        expect(freshA["C"] != freshB["C"] && freshA["S"] != freshB["S"], "production calls use fresh dynamic key and ephemeral entropy")
        expect(freshA["R"] == sealed["R"] && freshB["R"] == sealed["R"], "fresh calls do not reuse server session identifiers")
        print("PASS: \(count) XEAPI Swift offline checks")
    }
}
