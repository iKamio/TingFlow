import Foundation

struct UpdateManifest: Decodable, Equatable {
    let bundleID: String
    let version: String
    let build: Int
    let notes: String
    let pageURL: URL
    func validate(for bundle: String) throws {
        guard bundleID == bundle, build > 0, notes.utf8.count <= 32_000,
              UpdateVersion.parse(version) != nil, UpdatePolicy.safe(pageURL) else { throw UpdateFailure.invalid }
    }
}

enum UpdateFailure: LocalizedError {
    case address, invalid, network, notConfigured
    var errorDescription: String? {
        switch self {
        case .address: return "请填写不含凭据、查询参数或片段的 HTTPS 更新清单地址。"
        case .invalid: return "更新清单格式或应用标识不匹配，未使用该更新。"
        case .network: return "暂时无法读取更新清单，请检查网络或稍后重试。"
        case .notConfigured: return "尚未配置更新清单。私有 GitHub 仓库不能匿名检查，不会把 GitHub Token 内置到 App。"
        }
    }
}

enum UpdateVersion {
    static func parse(_ text: String) -> [Int]? {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part), number <= 1_000_000 else { return nil }
            result.append(number)
        }
        return result + Array(repeating: 0, count: 4 - result.count)
    }
    static func newer(version: String, build: Int, than current: String, currentBuild: Int) -> Bool {
        guard let remote = parse(version), let local = parse(current), build > 0 else { return false }
        for (a, b) in zip(remote, local) { if a != b { return a > b } }
        return build > currentBuild
    }
}

enum UpdatePolicy {
    static func safe(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil &&
        url.query == nil && url.fragment == nil && (url.port == nil || url.port == 443)
    }
    static func manifest(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), safe(url) else { throw UpdateFailure.address }
        return url
    }
}
