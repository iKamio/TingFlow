import Foundation
import CommonCrypto
import CryptoKit
import Security

/// Small independent implementation of the public weapi wire format, not an SDK.
/// Constants are protocol public material. No credentials or payloads are logged.
enum NeteaseCrypto {
    static func seal(_ object: [String: Any], secret: String? = nil) throws -> [String: String] {
        let key: String
        if let secret {
            guard secret.utf8.count == 16, secret.utf8.allSatisfy({ $0 < 128 }) else { throw NeteaseError.crypto }
            key = secret
        } else {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
            var result = [UInt8]()
            while result.count < 16 {
                var byte: UInt8 = 0
                guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw NeteaseError.crypto }
                if byte < 248 { result.append(alphabet[Int(byte) % 62]) }
            }
            key = String(decoding: result, as: UTF8.self)
        }
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let first = try aes(json, key: "0CoJUm6Qyw8W8jud").base64EncodedString()
        let params = try aes(Data(first.utf8), key: key).base64EncodedString()
        return ["params": params, "encSecKey": try rsa(key)]
    }

    private static func aes(_ data: Data, key: String) throws -> Data {
        let bytes = Array(data), keyBytes = Array(key.utf8), iv = Array("0102030405060708".utf8)
        var output = [UInt8](repeating: 0, count: bytes.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = output.count
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), keyBytes, keyBytes.count, iv,
                             bytes, bytes.count, &output, capacity, &length)
        guard status == kCCSuccess else { throw NeteaseError.crypto }
        return Data(output.prefix(length))
    }

    private static func rsa(_ secret: String) throws -> String {
        // RFC 5280 SPKI; Security expects the inner PKCS#1 RSAPublicKey (140 bytes).
        let publicSPKI = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB"
        guard let spki = Data(base64Encoded: publicSPKI), spki.count == 162 else { throw NeteaseError.crypto }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 1024]
        guard let key = SecKeyCreateWithData(Data(spki.suffix(140)) as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else { throw NeteaseError.crypto }
        var block = Data(repeating: 0, count: 112)
        block.append(contentsOf: secret.utf8.reversed())
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, block as CFData, nil) as Data?,
              encrypted.count == 128 else { throw NeteaseError.crypto }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = fields.keys.sorted().map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

extension NeteaseCrypto {
    /// Native EAPI wire format used by the authenticated daily/library and QR endpoints.
    static func sealEAPI(apiPath: String, object: [String: Any]) throws -> [String: String] {
        guard apiPath.hasPrefix("/api/"), !apiPath.contains("?"), !apiPath.contains("#") else { throw NeteaseError.crypto }
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: json, encoding: .utf8) else { throw NeteaseError.crypto }
        let digestInput = "nobody\(apiPath)use\(text)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(digestInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let message = "\(apiPath)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let encrypted = try aesECB(Data(message.utf8), key: "e82ckenh8dichen8")
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    private static func aesECB(_ data: Data, key: String) throws -> Data {
        let input = Array(data), keyBytes = Array(key.utf8)
        guard keyBytes.count == kCCKeySizeAES128 else { throw NeteaseError.crypto }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var count = 0
        let capacity = output.count
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                             keyBytes, keyBytes.count, nil, input, input.count,
                             &output, capacity, &count)
        guard status == kCCSuccess else { throw NeteaseError.crypto }
        return Data(output.prefix(count))
    }
}
