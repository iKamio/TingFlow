import Foundation

enum NeteasePlaybackMode: String, CaseIterable, Identifiable {
    case nativeV1, legacyStandard
    var id: String { rawValue }
}

/// Security, account and transport failures never trigger a new source chain.
enum NeteasePlaybackSafety {
    static func allowsSourceFallback(after error: Error) -> Bool {
        guard let value = error as? NeteaseError else { return false }
        return value == .unavailable
    }
    static func validateMediaCode(_ code: Int) throws {
        if code == 200 { return }
        if [301, 302, 401].contains(code) { throw NeteaseError.signedOut }
        if [-460, -462, 405].contains(code) { throw NeteaseError.playbackVerification(code) }
        if code == 429 { throw NeteaseError.rateLimited }
        if code == -110 || code == 404 { throw NeteaseError.unavailable }
        throw NeteaseError.mediaRejected(code)
    }
}

/// Memory-only numeric and allowlisted fields. No track/user IDs, URLs, cookies or body text.
struct NeteasePlaybackDiagnostic {
    let endpoint: String
    let wireProtocol: String
    let requestedLevel: String
    var httpStatus: Int?
    var businessCode: Int?
    var mediaCodes: [Int] = []
    var keyHTTPStatus: Int?
    var keyBusinessCode: Int?
    var negotiatingKey = false
    init(v1: Bool, level: String?) {
        endpoint = v1 ? "/song/enhance/player/url/v1" : "/song/enhance/player/url"
        wireProtocol = v1 ? "XEAPI" : "WEAPI"
        requestedLevel = v1 ? (["standard", "exhigh", "lossless"].contains(level ?? "") ? (level ?? "unknown") : "unknown") : "standard (legacy)"
    }
    private func safe(_ value: Int?) -> String { value.map { (-1_000_000...1_000_000).contains($0) ? String($0) : "unknown" } ?? "未提供" }
    var text: String {
        ["听流 · 网易云播放诊断 v2", "接口：" + endpoint, "协议：" + wireProtocol,
         "阶段：" + (negotiatingKey ? "公钥协商" : "播放地址请求"),
         "公钥 HTTP：" + safe(keyHTTPStatus), "公钥接口码：" + safe(keyBusinessCode),
         "请求级别：" + requestedLevel, "HTTP：" + safe(httpStatus), "接口码：" + safe(businessCode),
         "媒体码：" + (mediaCodes.isEmpty ? "未提供" : mediaCodes.prefix(8).map { safe($0) }.joined(separator: ", ")),
         "账号状态与播放接口分别核验；此摘要不是账号异常的判定。",
         "仅包含固定路由、请求级别和数值状态；不含地址、ID、Cookie、Token或响应原文。"].joined(separator: "\n")
    }
}
