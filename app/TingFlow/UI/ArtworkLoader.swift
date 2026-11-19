import Foundation
import UIKit
import ImageIO

private final class ArtworkRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ArtworkLoader.isAllowed) == true ? request : nil)
    }
}

actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let session: URLSession
    private var cache: [URL: Data] = [:]
    private var order: [URL] = []
    init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25
        session = URLSession(configuration: c, delegate: ArtworkRedirects(), delegateQueue: nil)
    }
    nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["music.163.com", "music.126.net", "kugou.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func data(_ url: URL) async throws -> Data {
        guard Self.isAllowed(url) else { throw MusicError.invalidURL }
        if let value = cache[url] { return value }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, Self.isAllowed(final),
              http.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= 4_000_000 else { throw MusicError.invalidResponse }
        var data = Data(); data.reserveCapacity(128_000)
        for try await byte in bytes {
            if data.count >= 4_000_000 { throw MusicError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        if order.count >= 12, let removed = order.first { cache.removeValue(forKey: removed); order.removeFirst() }
        cache[url] = data; order.append(url)
        return data
    }
    nonisolated static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 700,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
