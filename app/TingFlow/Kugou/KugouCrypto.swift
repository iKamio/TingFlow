import Foundation
import CryptoKit

// Independently written adapter. Protocol reference: MakcRe/KuGouMusicApi (MIT).
// See KUGOU-RESULT.md and KUGOU-NOTICE.md for provenance.
enum KugouCrypto {
    enum Signature { case web, android }
    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func signature(_ parameters: [String: String], body: Data = Data(), kind: Signature) -> String {
        let salt = kind == .web ? "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt" : "OIlwieks28dk2k092lksi2UIkp"
        // Web sorts the complete key=value strings; Android sorts keys. Sign raw
        // UTF-8 values, not percent-encoded query values, and never include signature.
        let fields: String
        switch kind {
        case .web: fields = parameters.map { "\($0.key)=\($0.value)" }.sorted().joined()
        case .android: fields = parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }.joined()
        }
        var input = Data((salt + fields).utf8)
        input.append(body); input.append(Data(salt.utf8))
        return md5(input)
    }
    /// Ordered scalar JSON: identical bytes are signed and sent. No dictionary-order dependency.
    enum Scalar { case string(String), number(String) }
    static func json(_ fields: [(String, Scalar)]) throws -> Data {
        func quoted(_ s: String) throws -> String {
            let bytes = try JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            guard let value = String(data: bytes, encoding: .utf8) else { throw KugouError.response }
            return value
        }
        let pairs = try fields.map { key, value -> String in
            let encoded: String
            switch value {
            case .string(let s): encoded = try quoted(s)
            case .number(let s):
                guard KugouMapping.decimal(s) != nil, let n = UInt64(s), n <= 9_007_199_254_740_991 else { throw KugouError.response }
                encoded = s
            }
            return try quoted(key) + ":" + encoded
        }
        return Data(("{" + pairs.joined(separator: ",") + "}").utf8)
    }
}
