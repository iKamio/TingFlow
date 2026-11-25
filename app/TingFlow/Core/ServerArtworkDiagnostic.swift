import Foundation
import CoreFoundation

/// Values accepted into a shareable diagnostic are enums or bounded numbers.
/// No URL, account/cover ID, filename, header value, response text or Error is retained.
struct ServerArtworkDiagnostic: Equatable, Sendable {
    enum Service: String, Sendable { case navidrome = "Navidrome", subsonic = "Subsonic" }
    enum Stage: String, Sendable {
        case validation = "本地请求校验", request = "等待响应", headers = "HTTP 响应头"
        case body = "读取响应正文", api = "Subsonic 错误响应", imageContainer = "图片容器校验"
        case imageDimensions = "图片尺寸校验", thumbnail = "界面缩略图解码"
        case uiDeadline = "界面等待截止", completed = "取图完成"
    }
    enum Issue: String, Sendable {
        case none = "无", missingID = "元数据未提供封面 ID", invalidContext = "账号或封面版本已变化"
        case signedOut = "未连接音乐服务器", http = "HTTP 请求被拒绝", authentication = "接口鉴权失败"
        case permission = "接口权限不足", api = "服务器返回 Subsonic 错误"
        case notFound = "服务器返回未找到封面", unexpectedMIME = "响应不是允许的图片类型"
        case invalidEnvelope = "接口错误响应无法识别", tooLarge = "响应超过安全上限"
        case empty = "图片正文为空", invalidContainer = "图片类型或完整性校验失败"
        case dimensions = "图片尺寸超过安全上限", thumbnail = "缩略图无法解码"
        case redirect = "拒绝响应目标变化或重定向", tls = "HTTPS 信任或安全连接失败"
        case timedOut = "网络等待超时", network = "网络连接未完成"
        case uiDeadline = "界面 20 秒等待截止", unknown = "未观察到可用的取图结果"
    }
    enum Origin: String, Sendable {
        case network = "当前取图请求", metadata = "当前库元数据"
        case cacheOrShared = "内存缓存或同图共享结果", ui = "当前界面任务"
    }
    enum MIME: String, Sendable {
        case jpeg = "image/jpeg", png = "image/png", webp = "image/webp", gif = "image/gif"
        case heic = "image/heic", heif = "image/heif", json = "application/json"
        case xml = "XML", html = "HTML", binary = "application/octet-stream"
        case missing = "未提供", other = "其他类型"
        static func classify(_ declared: String?) -> MIME {
            guard let declared else { return .missing }
            let value = declared.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            switch value {
            case "image/jpeg": return .jpeg
            case "image/png": return .png
            case "image/webp": return .webp
            case "image/gif": return .gif
            case "image/heic": return .heic
            case "image/heif": return .heif
            case "application/json": return .json
            case "application/xml", "text/xml": return .xml
            case "text/html", "application/xhtml+xml": return .html
            case "application/octet-stream": return .binary
            case "": return .missing
            default: return .other
            }
        }
        var isImage: Bool { [.jpeg, .png, .webp, .gif, .heic, .heif].contains(self) }
    }
    enum ImageFormat: String, Sendable {
        case jpeg = "JPEG", png = "PNG", webp = "WebP", gif = "GIF", heif = "HEIC/HEIF"
        case other = "其他格式", unobserved = "未观察到"
        static func classify(_ uti: String?) -> ImageFormat {
            guard let uti else { return .unobserved }
            switch uti {
            case "public.jpeg": return .jpeg
            case "public.png": return .png
            case "org.webmproject.webp": return .webp
            case "com.compuserve.gif": return .gif
            case "public.heic", "public.heif": return .heif
            default: return .other
            }
        }
    }
    enum APIStatus: String, Sendable { case unobserved = "未观察到", failed = "failed", ok = "ok", invalid = "格式无效" }

    let service: Service
    let pixels: Int
    var origin: Origin = .network
    var stage: Stage = .validation
    var issue: Issue = .none
    var httpStatus: Int?
    var apiCode: Int?
    var apiStatus: APIStatus = .unobserved
    var mime: MIME = .missing
    var imageFormat: ImageFormat = .unobserved
    var bytesReceived = 0
    var expectedBytes: Int64?

    init(service: Service, pixels: Int) {
        self.service = service
        self.pixels = pixels <= 320 ? 320 : 700
    }
    static func apiEnvelope(_ data: Data) -> (status: APIStatus, code: Int?)? {
        guard !data.isEmpty, data.count <= 65_536,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["subsonic-response"] as? [String: Any] else { return nil }
        let status: APIStatus
        switch body["status"] as? String {
        case "failed": status = .failed
        case "ok": status = .ok
        default: status = .invalid
        }
        let number = (body["error"] as? [String: Any])?["code"] as? NSNumber
        let code: Int?
        if let number, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, (-1_000_000...1_000_000).contains(number.doubleValue),
           number.doubleValue.rounded(.towardZero) == number.doubleValue {
            code = number.intValue
        } else { code = nil }
        return (status, code)
    }
    static func apiIssue(_ code: Int?) -> Issue {
        switch code {
        case 40, 41, 42, 43, 44: return .authentication
        case 50: return .permission
        case 70: return .notFound
        default: return .api
        }
    }
    private func safe(_ value: Int?, range: ClosedRange<Int>) -> String {
        guard let value, range.contains(value) else { return "未观察到" }
        return String(value)
    }
    var text: String {
        let length: String
        if let expectedBytes, expectedBytes >= 0 {
            length = expectedBytes <= 4_000_000 ? String(expectedBytes) : "超过 4,000,000"
        } else { length = "未提供" }
        return ["听流 · 服务器封面诊断 v1", "服务：" + service.rawValue,
                "接口：/rest/getCoverArt.view", "请求：POST · 令牌表单鉴权", "尺寸档：\(pixels) px",
                "来源：" + origin.rawValue, "阶段：" + stage.rawValue, "结果：" + issue.rawValue,
                "HTTP：" + safe(httpStatus, range: 100...599), "Subsonic 状态：" + apiStatus.rawValue,
                "Subsonic 接口码：" + safe(apiCode, range: -1_000_000...1_000_000),
                "响应类型：" + mime.rawValue, "图片格式：" + imageFormat.rawValue,
                "已读字节：" + safe(bytesReceived, range: 0...4_000_001), "声明字节：" + length,
                "缓存/共享结果没有新请求时，HTTP 与接口码标为未观察到。",
                "HTTP 200 不代表取图成功；界面截止不代表服务器没有封面。",
                "仅有固定路由、受限分类与数值；不含地址、账号、封面 ID、Cookie、Token 或响应原文。"].joined(separator: "\n")
    }
}

struct ServerArtworkResult {
    let data: Data?
    let diagnostic: ServerArtworkDiagnostic
}

/// The only error allowed to pass the shared artwork cache's sanitization gate.
/// Contains the allowlisted value model, never an underlying transport Error.
struct ServerArtworkDiagnosticFailure: Error, LocalizedError, Equatable {
    let diagnostic: ServerArtworkDiagnostic
    var errorDescription: String? { "封面未载入，请查看脱敏封面诊断。" }
}
