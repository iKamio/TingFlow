import Foundation

/// Platform-reported, entitlement-checked requests. No built-in matching service.
enum NeteaseAudioPolicy {
    static func level(for quality: AudioQuality) -> String {
        switch quality {
        case .standard: return "standard"
        case .high: return "exhigh"
        case .lossless: return "lossless"
        }
    }

    static func payload(songID: String, quality: AudioQuality) throws -> [String: Any] {
        guard NeteaseMapping.id(songID) == songID else { throw NeteaseError.response }
        // Native v1 accepts a JSON array encoded as a string, not a Swift array.
        return ["ids": "[\(songID)]", "level": level(for: quality), "encodeType": "flac"]
    }

    static func legacyPayload(songID: String) -> [String: Any] {
        // Preserve the device-proven legacy request, strictly as a standard-quality safety net.
        ["ids": "[\"\(songID)\"]", "br": 128000]
    }

    static func isTransientTransport(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet: return true
        default: return false // Includes cancellation, TLS/certificate and redirect failures.
        }
    }

    static func displayQuality(type: String, bitrate: Int, level: String?, isPreview: Bool) -> String {
        let codec: String
        switch type {
        case "mp3": codec = "MP3"
        case "flac": codec = "FLAC"
        case "m4a", "mp4": codec = "AAC/MP4"
        case "aac": codec = "AAC"
        default: codec = "平台音频"
        }
        var parts: [String] = []
        // Level alone is not proof of codec/bitrate: servers may downgrade a requested level.
        if type != "flac", bitrate > 0 {
            if level == "standard", bitrate <= 128000 { parts.append("标准") }
            if level == "exhigh", bitrate >= 320000 { parts.append("高品质") }
        }
        parts.append(codec)
        if bitrate > 0 { parts.append("\(bitrate / 1000) kbps") }
        if isPreview { parts.insert("平台试听", at: 0) }
        return parts.joined(separator: " · ")
    }
}
