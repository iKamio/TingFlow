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
    private let cache = PublicArtworkCache()
    init() {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        // This session handles public artwork only. Respect CDN freshness headers
        // across launches without persisting any account's authenticated media.
        c.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 64_000_000, diskPath: "TingFlow-PublicArtwork-v1")
        c.requestCachePolicy = .useProtocolCachePolicy
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25
        c.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: c, delegate: ArtworkRedirects(), delegateQueue: nil)
    }
    nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        if host == "api.lrc.cx" {
            guard url.path == "/cover", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 2, Set(items.map(\.name)) == ["title", "artist"] else { return false }
            return items.allSatisfy { item in
                guard let value = item.value else { return false }
                return !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
        }
        if url.query != nil {
            guard host == "music.126.net" || host.hasSuffix(".music.126.net") ||
                    host == "music.163.com" || host.hasSuffix(".music.163.com"),
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 1, items[0].name == "param", let value = items[0].value,
                  value.range(of: #"^[0-9]{2,4}y[0-9]{2,4}$"#, options: .regularExpression) != nil else { return false }
        }
        return ["music.163.com", "music.126.net", "kugou.com", "mzstatic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func data(_ url: URL) async throws -> Data {
        guard Self.isAllowed(url) else { throw MusicError.invalidURL }
        let requestURL = Self.requestURL(url)
        return try await cache.data(for: requestURL) { [self] in try await download(requestURL) }
    }
    nonisolated static func requestURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "music.126.net" || host.hasSuffix(".music.126.net") ||
                host == "music.163.com" || host.hasSuffix(".music.163.com"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // Lists and Now Playing share one thumbnail/key. Fetching an unbounded
        // original needlessly exceeds the four-megabyte safety limit on some albums.
        parts.queryItems = [URLQueryItem(name: "param", value: "700y700")]
        return parts.url ?? url
    }
    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, Self.isAllowed(final),
              Self.acceptsMIME(http.mimeType),
              response.expectedContentLength <= 4_000_000 else {
            session.configuration.urlCache?.removeCachedResponse(for: request)
            throw MusicError.invalidResponse
        }
        var data = Data(); data.reserveCapacity(128_000)
        for try await byte in bytes {
            if data.count >= 4_000_000 {
                session.configuration.urlCache?.removeCachedResponse(for: request)
                throw MusicError.invalidResponse
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard Self.thumbnail(data) != nil else {
            session.configuration.urlCache?.removeCachedResponse(for: request)
            throw MusicError.invalidResponse
        }
        return data
    }
    nonisolated static func acceptsMIME(_ mime: String?) -> Bool {
        // Some image CDNs label valid bytes as generic binary; the bounded
        // ImageIO decode below, rather than the MIME alone, decides validity.
        guard let mime = mime?.lowercased() else { return true }
        return mime.hasPrefix("image/") || mime == "application/octet-stream"
    }
    nonisolated static func thumbnail(_ data: Data) -> UIImage? {
        guard !data.isEmpty, data.count <= 4_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 80_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 700,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
