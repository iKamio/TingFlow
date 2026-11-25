import Foundation

/// Optional, public title/artist lookup only. This transport never has platform credentials.
private final class LyricRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ExternalMetadataFailure: LocalizedError {
    case missingNames, unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingNames: return "歌曲缺少歌名或歌手，无法匹配外部歌词。"
        case .unavailable: return "外部歌词服务暂时不可用，请稍后重试。"
        case .invalidResponse: return "没有找到可用歌词，或服务返回了无法识别的内容。"
        }
    }
}

actor ExternalMetadata {
    static let shared = ExternalMetadata()
    private let session: URLSession
    private var cache: [URL: String] = [:]
    private var order: [URL] = []
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 18
        session = URLSession(configuration: config, delegate: LyricRedirectBlocker(), delegateQueue: nil)
    }
    func lyrics(for song: Song) async throws -> String {
        guard let url = song.metadataURL("lyrics") else { throw ExternalMetadataFailure.missingNames }
        try Task.checkCancellation()
        if let text = cache[url] { return text }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain, application/x-lrc;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              ["text/plain", "application/x-lrc", "text/lrc"].contains(http.mimeType?.lowercased() ?? ""),
              response.expectedContentLength <= 512_000 else { throw ExternalMetadataFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512_000 else { throw ExternalMetadataFailure.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        let text = try Self.decode(data)
        if order.count >= 40, let oldest = order.first { order.removeFirst(); cache.removeValue(forKey: oldest) }
        cache[url] = text; order.removeAll { $0 == url }; order.append(url)
        return text
    }
    static func decode(_ data: Data) throws -> String {
        guard data.count <= 512_000, let raw = String(data: data, encoding: .utf8) else { throw ExternalMetadataFailure.invalidResponse }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "")
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("{"), !text.hasPrefix("[\""),
              !["null", "undefined", "not found", "暂无歌词", "未找到歌词"].contains(text.lowercased()) else { throw ExternalMetadataFailure.invalidResponse }
        return text
    }
}
