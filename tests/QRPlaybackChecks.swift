import Foundation

@main struct QRPlaybackChecks {
    static func main() {
        let base = Date(timeIntervalSince1970: 1000)
        var window = NeteaseQRWindow(now: base)
        precondition(!window.isExpired(at: base), "fresh QR")
        precondition(window.beginCheck(at: base), "active polling")
        window.pause()
        precondition(!window.beginCheck(at: base.addingTimeInterval(1)), "paused polling")
        window.resume()
        precondition(window.beginCheck(at: base.addingTimeInterval(2)), "resume polling")
        let expired = NeteaseQRWindow(now: base)
        precondition(expired.isExpired(at: base.addingTimeInterval(180)), "QR deadline")
        let fixture = Data("{\"ErrorCode\":\"NoCompatibleStream\",\"MediaSources\":[{\"Protocol\":\"Http\",\"Container\":\"mkv,strm\",\"Path\":\"https://secret.invalid/x\",\"Id\":\"secret-id\",\"SupportsDirectStream\":false,\"MediaStreams\":[{\"Type\":\"Audio\",\"Codec\":\"opus\"}]}]}".utf8)
        let report = EmbyPlaybackDiagnostic.make(fixture)
        precondition(report.contains("NoCompatibleStream"), "safe error code")
        precondition(report.contains("http") && report.contains("opus"), "format diagnostics")
        precondition(!report.contains("secret.invalid") && !report.contains("secret-id"), "no URL or ID leakage")
        print("PASS: QR pause/resume and redacted Emby playback diagnostics")
    }
}
