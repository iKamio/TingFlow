import Foundation

/// Allowlisted diagnostics only: never include names, IDs, Path, URLs, credentials or raw JSON.
enum EmbyPlaybackDiagnostic {
    private static let protocols: Set<String> = ["file", "http", "rtsp", "rtmp", "udp", "ftp"]
    private static let codecs: Set<String> = ["mp3", "mp2", "aac", "flac", "alac", "opus", "vorbis", "ape", "wma", "wmav1", "wmav2", "wmapro", "dts", "ac3", "eac3", "dsd_lsbf", "dsd_msbf", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le", "pcm_s16be", "pcm_s24be", "pcm_s32be"]
    private static let containers: Set<String> = ["mp3", "mp2", "aac", "adts", "m4a", "mp4", "flac", "wav", "wave", "aif", "aiff", "ogg", "oga", "ape", "wma", "asf", "caf", "webm", "m3u8", "strm", "ts", "dsf", "dff"]
    static func make(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "TingFlow Emby 播放诊断 v1\nPlaybackInfo 不是可解析的对象；未导出原始响应。"
        }
        let error = root["ErrorCode"] as? String
        let recognized = ["NotAllowed", "NoCompatibleStream", "RateLimitExceeded"]
        let errorText = error.map { recognized.contains($0) ? $0 : "非标准值（已隐藏）" }
            ?? (root["ErrorCode"] == nil || root["ErrorCode"] is NSNull ? "未提供" : "非字符串（已隐藏）")
        let sources = (root["MediaSources"] as? [[String: Any]]) ?? (root["MediaStreams"] != nil ? [root] : nil)
        var report = ["TingFlow Emby 播放诊断 v1", "客户端：仅渐进式直放；转码未启用", "ErrorCode：\(errorText)", "MediaSources：\(sources?.count ?? 0)"]
        for (index, item) in (sources ?? []).prefix(8).enumerated() {
            report.append("媒体源 \(index + 1)：")
            let proto = item["Protocol"] as? String
            report.append("  Protocol：" + known(proto, values: protocols))
            let container = item["Container"] as? String
            let parts = container?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            report.append("  Container：" + (parts.isEmpty ? "未提供" : parts.prefix(8).map { containers.contains($0) ? $0 : "其它" }.joined(separator: ",")))
            let streams = item["MediaStreams"] as? [[String: Any]]
            report.append("  MediaStreams：\(streams?.count ?? 0)" + (streams == nil ? "（未提供）" : ""))
            let audio = (streams ?? []).filter { ($0["Type"] as? String)?.lowercased() == "audio" }
            report.append("  AudioCodec：" + (audio.isEmpty ? "未提供" : audio.prefix(4).map { known($0["Codec"] as? String, values: codecs) }.joined(separator: ",")))
            for key in ["SupportsDirectPlay", "SupportsDirectStream", "SupportsTranscoding", "RequiresOpening", "RequiresClosing", "IsInfiniteStream", "RequiresLooping"] {
                report.append("  \(key)：" + ((item[key] as? Bool).map { $0 ? "true" : "false" } ?? "未提供"))
            }
            for key in ["DirectStreamUrl", "TranscodingUrl"] {
                report.append("  \(key)存在：" + (((item[key] as? String)?.isEmpty == false) ? "true" : "false"))
            }
        }
        report.append("未包含服务器地址、文件路径、用户/媒体ID、Token、Cookie或原始响应。")
        return report.joined(separator: "\n")
    }
    private static func known(_ value: String?, values: Set<String>) -> String {
        guard let value else { return "未提供" }
        let normalized = value.lowercased().trimmingCharacters(in: .whitespaces)
        return values.contains(normalized) ? normalized : "其它（已隐藏）"
    }
}
