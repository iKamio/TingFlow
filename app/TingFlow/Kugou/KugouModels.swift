import Foundation

/// Standard KuGou app (1005); credentials are never shared with scripts or other platforms.
struct KugouDevice: Codable, Equatable {
    let mid: String
    let dev: String
    static func fresh() -> Self {
        // Installation-local random numeric MID, not an actual device fingerprint.
        Self(mid: String(UInt64.random(in: 100_000_000_000_000_000...999_999_999_999_999_999)),
             dev: UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased())
    }
    var isValid: Bool { KugouMapping.decimal(mid, max: 48) != nil && dev.count == 32 && dev.allSatisfy(\.isHexDigit) }
}

struct KugouCredential: Codable, Equatable {
    let version: Int
    let userID: String
    let token: String
    let device: KugouDevice
    init(userID: String, token: String, device: KugouDevice) throws {
        version = 1; self.userID = userID; self.token = token; self.device = device
        guard isValid else { throw KugouError.response }
    }
    var isValid: Bool {
        version == 1 && KugouMapping.decimal(userID) != nil && userID != "0" && device.isValid &&
        !token.isEmpty && token.utf8.count <= 1024 && token.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95,46,126].contains($0)
        }
    }
}

struct KugouProfile: Equatable {
    let id: String
    let name: String
    let avatar: URL?
}

struct KugouPlaylist: Identifiable, Equatable {
    enum Kind: String { case created, collected, unknown }
    let id: String                 // account-local listid, NOT global_collection_id
    let accountScope: String
    let name: String
    let ownerID: String?
    let trackCount: Int
    let artworkURL: URL?
    let kind: Kind
    let globalCollectionID: String?
}

struct KugouPage<Element> {
    let items: [Element]
    let total: Int?
    let rawCount: Int
    let fingerprint: String
}

enum KugouQRResult {
    case expired, waiting, scanned, authorized(KugouCredential)
}

enum KugouError: Error, LocalizedError, Equatable {
    case network, response, unsafeURL, signedOut, identity, storage, rejected, verificationRequired
    case rateLimited, pagination, expired, unavailable
    var errorDescription: String? {
        switch self {
        case .network: return "无法连接酷狗，请检查网络后重试。"
        case .response: return "酷狗返回的数据无法识别，未替换已有资料。"
        case .unsafeURL: return "酷狗请求地址或重定向不符合安全策略。"
        case .signedOut: return "酷狗登录凭据已失效，请重新扫码。"
        case .identity: return "酷狗返回的账号与当前凭据不一致，已停止读取。"
        case .storage: return "此机酷狗凭据存储不可用，请解锁设备后重试。"
        case .rejected: return "酷狗未接受请求，请稍后重试；未执行云端修改。"
        case .verificationRequired: return "酷狗要求额外安全验证。请先在官方 App 处理后重新扫码；听流不会模拟或绕过验证。"
        case .rateLimited: return "酷狗请求过于频繁，请稍后重试。"
        case .pagination: return "歌单分页不完整或数据发生变化，请重新读取；未用部分结果覆盖旧资料。"
        case .expired: return "二维码已过期，请主动重新生成。"
        case .unavailable: return "当前酷狗接口暂不可用。"
        }
    }
    static func message(_ error: Error) -> String {
        (error as? KugouError)?.errorDescription ?? KugouError.network.errorDescription!
    }
}

/// Bounded wall-clock lifetime continues while backgrounded; checks do not.
struct KugouQRWindow {
    let expiresAt: Date
    private(set) var checks = 0
    private(set) var paused = false
    init(now: Date = Date()) { expiresAt = now.addingTimeInterval(120) }
    func live(now: Date = Date()) -> Bool { now < expiresAt && checks <= 48 }
    func valid(now: Date = Date()) -> Bool { live(now: now) && checks < 48 }
    mutating func pause() { paused = true }
    mutating func resume(now: Date = Date()) -> Bool {
        guard valid(now: now) else { return false }; paused = false; return true
    }
    mutating func beginCheck(now: Date = Date()) -> Bool {
        guard !paused, valid(now: now) else { return false }; checks += 1; return true
    }
}

/// No silently truncated success: total drift, repeated pages, early empty pages and hard caps fail closed.
struct KugouPageWindow {
    let pageSize: Int
    let maxPages: Int
    private(set) var page = 0
    private(set) var received = 0
    private var knownTotal: Int?
    private var fingerprints: Set<String> = []
    init(pageSize: Int, maxPages: Int = 200) { self.pageSize = pageSize; self.maxPages = maxPages }
    mutating func accept<T>(_ value: KugouPage<T>) throws -> Bool {
        guard page < maxPages, (0...pageSize).contains(value.rawCount), value.items.count == value.rawCount else { throw KugouError.pagination }
        if let total = value.total {
            guard total >= 0, total <= pageSize * maxPages, knownTotal == nil || knownTotal == total else { throw KugouError.pagination }
            knownTotal = total
        }
        if value.rawCount > 0 {
            guard !value.fingerprint.isEmpty, fingerprints.insert(value.fingerprint).inserted else { throw KugouError.pagination }
        }
        page += 1; received += value.rawCount
        if let total = knownTotal {
            guard received <= total, value.rawCount > 0 || received == total else { throw KugouError.pagination }
            if received == total { return false }
            guard value.rawCount == pageSize else { throw KugouError.pagination }
        } else if value.rawCount < pageSize { return false }
        guard page < maxPages else { throw KugouError.pagination }
        return true
    }
}
