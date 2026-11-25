/*
 XEAPI protocol adapted from NeteaseCloudMusicApiEnhanced/api-enhanced,
 util/crypto.js and module/register_xeapikey.js at
 23d9e9d7ee5dfeccfc3b15916ccd9da1f76d3ea4.
 The MIT License (MIT) — Copyright (c) 2013-2022 Binaryify
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
*/
import Foundation
import CoreFoundation
import CommonCrypto
import CryptoKit
import Security
import zlib

/// Offline wire codec only. No network, persistence, logging, retries or session reuse.
/// Protocol constants below are public material, not application credentials.
enum NeteaseXEAPI {
    struct PublicKeyState {
        let publicKey: Data // raw X25519, exactly 32 bytes (not SPKI)
        let version: String
        let sk: String
    }

    /// Intentionally carries no server text, underlying error, URL or payload.
    enum Failure: Error, Equatable {
        case invalidInput, invalidKey, invalidResponse, invalidSignature, sizeLimit, cryptography
    }

    static let maximumResponseBytes = 2 * 1024 * 1024
    static let maximumRequestBytes = 1024 * 1024
    private static let maximumKeyDocumentBytes = 64 * 1024
    private static let staticKey = Data([
        0xab, 0x1d, 0x5a, 0x43, 0x0f, 0x6b, 0xb0, 0x4a,
        0x3f, 0x01, 0xe8, 0x1d, 0xdd, 0x72, 0xbd, 0x91,
        0x6d, 0x5c, 0xe5, 0x91, 0x24, 0x8a, 0xc1, 0x28,
        0x71, 0x48, 0x06, 0xd7, 0xf8, 0xfb, 0x1b, 0x84
    ])
    // IMPORTANT: ASCII literal; never base64-decode this HMAC key.
    private static let signKey = SymmetricKey(data: Data(
        "mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==".utf8))
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)

    static func seal(apiPath: String, payload: [String: Any], state: PublicKeyState) throws -> [String: String] {
        try seal(apiPath: apiPath, payload: payload, state: state, entropy: Entropy(
            dynamicKey: random(16), mask: random(16), ephemeralPrivateKey: random(32), nonce: random(12)))
    }

    /// Internal, explicit test seam. Production callers must use the overload above.
    /// No global RNG override and no retained private material.
    struct Entropy {
        let dynamicKey: Data
        let mask: Data
        let ephemeralPrivateKey: Data
        let nonce: Data
    }

    static func seal(apiPath: String, payload: [String: Any], state: PublicKeyState,
                     entropy: Entropy) throws -> [String: String] {
        guard apiPath.hasPrefix("/api/"), apiPath.utf8.count > 5, apiPath.utf8.count <= 2048,
              apiPath.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || [UInt8(47), 45, 46, 95].contains($0) }),
              !apiPath.contains("//"),
              !apiPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              entropy.dynamicKey.count == 16, entropy.mask.count == 16,
              entropy.ephemeralPrivateKey.count == 32, entropy.nonce.count == 12 else { throw Failure.invalidInput }
        try validateState(state)
        let plaintext = try buildPlaintext(payload)
        let inner = try aesECB(plaintext, key: staticKey, encrypt: true)
        let bytes = Array(inner), mask = Array(entropy.mask)
        let xored = bytes.enumerated().map { $0.element ^ mask[$0.offset & 15] }
        let rotation = Int(mask[0] & 15) % xored.count
        var transformed = entropy.mask
        transformed.append(contentsOf: xored.dropFirst(rotation))
        transformed.append(contentsOf: xored.prefix(rotation))
        let c = try aesECB(transformed, key: entropy.dynamicKey, encrypt: true)

        let s: Data
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: state.publicKey)
            let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: entropy.ephemeralPrivateKey)
            let ephemeralRaw = ephemeral.publicKey.rawRepresentation
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
            let shared = secret.withUnsafeBytes { Data($0) }
            guard shared.contains(where: { $0 != 0 }) else { throw Failure.invalidKey }
            // RFC 5869 Extract(salt=32 zero bytes), Expand(info=ephemeralRaw, L=16).
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared),
                salt: Data(repeating: 0, count: 32), info: ephemeralRaw, outputByteCount: 16)
            let text = Data("\(entropy.dynamicKey.base64EncodedString())|android|\(state.sk)".utf8)
            let box = try AES.GCM.seal(text, using: key, nonce: AES.GCM.Nonce(data: entropy.nonce))
            var packed = ephemeralRaw
            packed.append(entropy.nonce)
            packed.append(box.ciphertext)
            packed.append(box.tag)
            s = packed
        } catch let failure as Failure { throw failure }
        catch { throw Failure.cryptography }
        let r = try aesECB(Data("\(state.version)|".utf8), key: staticKey, encrypt: true)
        return ["C": c.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
                "S": s.base64EncodedString(), "R": r.base64EncodedString()]
    }

    static func registration(device: String, timestamp: String? = nil, nonce: String? = nil) throws -> [String: String] {
        guard !device.isEmpty, device.utf8.count <= 512,
              !device.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidInput }
        let time = timestamp ?? String(Int64(Date().timeIntervalSince1970 * 1000))
        let requestNonce: String
        if let nonce { requestNonce = nonce } else {
            // Rejection sampling: uniform decimal digits, unlike byte % 10 alone.
            var digits = [UInt8]()
            while digits.count < 16 {
                for byte in try random(32) where byte < 250 {
                    digits.append(48 + byte % 10)
                    if digits.count == 16 { break }
                }
            }
            requestNonce = String(decoding: digits, as: UTF8.self)
        }
        guard validTimestamp(time), validNonce(requestNonce) else { throw Failure.invalidInput }
        return ["appVersion": "9.5.61", "currentKeyVersion": "", "deviceId": device,
                "nonce": requestNonce, "os": "android", "requestType": "active",
                "signature": signature(time, requestNonce).base64EncodedString(),
                "t1": "", "t2": "", "timestamp": time, "uid": ""]
    }

    static func publicKey(from data: Data, nonce: String) throws -> PublicKeyState {
        guard validNonce(nonce) else { throw Failure.invalidInput }
        guard data.count <= maximumKeyDocumentBytes else { throw Failure.sizeLimit }
        let root = try object(data)
        guard let code = root["code"] as? NSNumber, !isBoolean(code), code.doubleValue == 200,
              let body = root["data"] as? [String: Any],
              let encrypted = body["encryptedData"] as? String,
              let supplied = body["signature"] as? String,
              let timestamp = timestampString(body["timestamp"]), validTimestamp(timestamp) else { throw Failure.invalidResponse }
        let mac = try base64(supplied, maximumBytes: 32, failure: .invalidSignature)
        guard mac.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(mac,
                authenticating: Data((timestamp + nonce).utf8), using: signKey) else { throw Failure.invalidSignature }
        // Verify with CryptoKit's constant-time authenticator BEFORE decrypting.
        // Upstream signs timestamp+nonce, NOT encryptedData; HTTPS remains mandatory.
        let ciphertext = try base64(encrypted, maximumBytes: maximumKeyDocumentBytes, failure: .invalidResponse)
        let decoded = try object(aesECB(ciphertext, key: staticKey, encrypt: false))
        guard let raw = decoded["publicKey"] as? String,
              let version = decoded["version"] as? String, let sk = decoded["sk"] as? String else { throw Failure.invalidKey }
        let key = try base64(raw, maximumBytes: 32, failure: .invalidKey)
        let state = PublicKeyState(publicKey: key, version: version, sk: sk)
        try validateState(state)
        // Validate low-order peers too; a fixed, public probe scalar is NOT used to seal.
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)
            let probe = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
            let shared = try probe.sharedSecretFromKeyAgreement(with: peer)
            guard shared.withUnsafeBytes({ $0.contains(where: { $0 != 0 }) }) else { throw Failure.invalidKey }
        } catch { throw Failure.invalidKey }
        return state
    }

    static func response(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw Failure.invalidResponse }
        guard data.count <= maximumResponseBytes + 16 else { throw Failure.sizeLimit }
        // Plain JSON business failures are legal. Never fall back to plaintext
        // after an AES/padding/gzip/JSON failure on the encrypted path.
        if let plain = try? JSONSerialization.jsonObject(with: data) {
            guard data.count <= maximumResponseBytes else { throw Failure.sizeLimit }
            guard let result = plain as? [String: Any] else { throw Failure.invalidResponse }
            return result
        }
        let decrypted = try aesECB(data, key: eapiKey, encrypt: false)
        guard decrypted.count <= maximumResponseBytes else { throw Failure.sizeLimit }
        let decoded: Data
        if decrypted.starts(with: [0x1f, 0x8b]) { decoded = try gunzip(decrypted) }
        else { decoded = decrypted }
        return try object(decoded)
    }

    /// Swift dictionaries have no JS insertion order: use UTF-16-sorted keys.
    /// Values follow JS String(value), NOT JSON.stringify(value). e_r is omitted.
    static func buildPlaintext(_ payload: [String: Any]) throws -> Data {
        guard payload.count <= 1024 else { throw Failure.sizeLimit }
        var content = ""
        for key in payload.keys.filter({ $0 != "e_r" }).sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
            let value = try jsString(payload[key]!, depth: 0, arrayElement: false)
            let pair = try formComponent(key) + "=" + formComponent(value)
            guard content.utf8.count + pair.utf8.count + (content.isEmpty ? 0 : 1) <= maximumRequestBytes else { throw Failure.sizeLimit }
            if !content.isEmpty { content += "&" }
            content += pair
        }
        var fields = ["queryString": "e_r=true"]
        if !content.isEmpty { fields["content"] = content }
        do {
            let result = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
            guard result.count <= maximumRequestBytes else { throw Failure.sizeLimit }
            return result
        } catch let failure as Failure { throw failure }
        catch { throw Failure.invalidInput }
    }

    private static func formComponent(_ text: String) throws -> String {
        guard text.utf8.count <= maximumRequestBytes else { throw Failure.sizeLimit }
        let hex = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        for byte in text.utf8 {
            // WHATWG application/x-www-form-urlencoded: '*' stays, '~' escapes.
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
                [UInt8(42), 45, 46, 95].contains(byte) { output.append(byte) }
            else if byte == 32 { output.append(43) }
            else { output.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]]) }
            guard output.count <= maximumRequestBytes else { throw Failure.sizeLimit }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func jsString(_ value: Any, depth: Int, arrayElement: Bool) throws -> String {
        guard depth <= 8 else { throw Failure.invalidInput }
        if let text = value as? String {
            guard text.utf8.count <= maximumRequestBytes else { throw Failure.sizeLimit }
            return text
        }
        if value is NSNull { return arrayElement ? "" : "null" }
        if let number = value as? NSNumber {
            if isBoolean(number) { return number.boolValue ? "true" : "false" }
            return try jsNumber(number.doubleValue)
        }
        if let array = value as? [Any] {
            guard array.count <= 1024 else { throw Failure.sizeLimit }
            var result = ""
            for (index, element) in array.enumerated() {
                let text = try jsString(element, depth: depth + 1, arrayElement: true)
                guard result.utf8.count + text.utf8.count + (index == 0 ? 0 : 1) <= maximumRequestBytes else { throw Failure.sizeLimit }
                if index != 0 { result += "," }
                result += text
            }
            return result
        }
        if value is [String: Any] { return "[object Object]" }
        throw Failure.invalidInput
    }

    /// Convert Swift's shortest Double spelling to JS's decimal/exponent cutoffs.
    /// Send identifiers as strings if they must not pass through IEEE-754 Number.
    private static func jsNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw Failure.invalidInput }
        if value == 0 { return "0" }
        let sign = value < 0 ? "-" : ""
        let parts = String(abs(value)).lowercased().split(separator: "e")
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(mantissa.joined())
        var point = mantissa[0].count + exponent
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        if abs(value) >= 1e21 || abs(value) < 1e-6 {
            let exp = point - 1
            let tail = digits.count > 1 ? "." + String(digits.dropFirst()) : ""
            return sign + String(digits[0]) + tail + "e" + (exp >= 0 ? "+" : "") + String(exp)
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(digits) }
        if point >= digits.count { return sign + String(digits) + String(repeating: "0", count: point - digits.count) }
        return sign + String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
    }

    private static func validateState(_ state: PublicKeyState) throws {
        guard state.publicKey.count == 32, state.publicKey.contains(where: { $0 != 0 }),
              !state.version.isEmpty, state.version.utf8.count <= 256,
              !state.sk.isEmpty, state.sk.utf8.count <= 4096,
              [state.version, state.sk].allSatisfy({ text in
                  !text.contains("|") && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else { throw Failure.invalidKey }
    }

    private static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func validTimestamp(_ value: String) -> Bool {
        (1...20).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func isBoolean(_ value: NSNumber) -> Bool { CFGetTypeID(value) == CFBooleanGetTypeID() }
    private static func timestampString(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, !isBoolean(number) { return number.stringValue }
        return nil
    }
    private static func signature(_ timestamp: String, _ nonce: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data((timestamp + nonce).utf8), using: signKey))
    }
    private static func base64(_ text: String, maximumBytes: Int, failure: Failure) throws -> Data {
        guard text.utf8.count <= ((maximumBytes + 2) / 3) * 4 else { throw failure }
        guard let decoded = Data(base64Encoded: text), decoded.count <= maximumBytes,
              decoded.base64EncodedString() == text else { throw failure }
        return decoded
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
            return result
        } catch { throw Failure.invalidResponse }
    }
    private static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.cryptography }
        return data
    }
    private static func aesECB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16 || key.count == 32 else { throw Failure.invalidKey }
        guard data.count <= maximumResponseBytes + 16 else { throw Failure.sizeLimit }
        if !encrypt { guard !data.isEmpty, data.count % 16 == 0 else { throw Failure.invalidResponse } }
        let input = Array(data), bytes = Array(key)
        var output = [UInt8](repeating: 0, count: data.count + 16)
        let capacity = output.count
        var written = 0
        let status = CCCrypt(encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            bytes, bytes.count, nil, input, input.count, &output, capacity, &written)
        guard status == kCCSuccess else { throw Failure.cryptography }
        return Data(output.prefix(written))
    }

    private static func gunzip(_ input: Data) throws -> Data {
        guard input.count >= 18 else { throw Failure.invalidResponse }
        // Gzip ISIZE is untrusted/modulo 2^32: precheck it, AND bound actual output.
        let trailer = Array(input.suffix(4))
        let advertised = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 |
                         UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        guard advertised <= UInt32(maximumResponseBytes) else { throw Failure.sizeLimit }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.cryptography }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { raw -> Data in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let allowance = min(chunk.count, maximumResponseBytes - result.count + 1)
                let status = chunk.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(allowance)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = allowance - Int(stream.avail_out)
                // Check before appending/allocating result storage; one scratch byte
                // detects overflow even when output is exactly at the cap.
                guard produced <= maximumResponseBytes - result.count else { throw Failure.sizeLimit }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw Failure.invalidResponse } // no trailing/concatenated members
                    return result
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw Failure.invalidResponse }
            }
        }
    }
}
