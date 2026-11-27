import AVFoundation

struct BeatTransitionResult {
    let plan: BeatTransitionPlan?
    let message: String
}
/// Reads at most two short local PCM windows, in memory, off the UI actor.
/// Remote/authenticated assets intentionally fail closed: AVAssetReader is not a bounded HTTPS downloader.
/// Do not pass a resolved remote URL to a new public URLSession or write a whole song to disk to enable this.
enum BeatTransitionAnalyzer {
    static func analyze(outgoing: PlaybackResource, incoming: PlaybackResource,
                        duration: Double, fade: Double) async -> BeatTransitionResult {
        guard outgoing.url.isFileURL, incoming.url.isFileURL,
              outgoing.headers.isEmpty, incoming.headers.isEmpty,
              !outgoing.requiresResourceLoader, !incoming.requiresResourceLoader,
              !outgoing.isPreview, !incoming.isPreview else {
            return BeatTransitionResult(plan: nil, message: "固定淡化 · 远程或鉴权音频不做额外下载分析")
        }
        let task = Task.detached(priority: .utility) { () -> BeatTransitionResult in
            do {
                try Task.checkCancellation()
                let tailStart = max(0, duration - fade - 1)
                let tail = try await read(outgoing.url, start: tailStart, seconds: min(12, fade + 1))
                try Task.checkCancellation()
                let head = try await read(incoming.url, start: 0, seconds: 3)
                try Task.checkCancellation()
                let plan = BeatOnsetAnalysis.plan(outgoing: tail, incoming: head, duration: duration, requestedFade: fade)
                return BeatTransitionResult(plan: plan, message: plan == nil
                    ? "固定淡化 · 未检测到安全范围内的起音" : "本机起音对齐 · 最大偏移 0.35 秒")
            } catch {
                return BeatTransitionResult(plan: nil, message: "固定淡化 · 本机解码分析不可用")
            }
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    private enum AnalysisError: Error { case unavailable }
    private static func read(_ url: URL, start: Double, seconds: Double) async throws -> [BeatOnset] {
        guard url.isFileURL, start.isFinite, start >= 0, seconds.isFinite, seconds > 0, seconds <= 12 else { throw AnalysisError.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent),
              let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AnalysisError.unavailable }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 11_025,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.unavailable }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 11_025),
                                      duration: CMTime(seconds: seconds, preferredTimescale: 11_025))
        guard reader.startReading() else { throw AnalysisError.unavailable }
        defer { reader.cancelReading() }
        let maximum = Int(seconds * 11_025)
        var pcm = [Float](); pcm.reserveCapacity(maximum)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while reader.status == .reading, pcm.count < maximum {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AnalysisError.unavailable }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw AnalysisError.unavailable }
            let count = min(maximum - pcm.count, CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            guard count > 0, count <= 132_300 else { throw AnalysisError.unavailable }
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw AnalysisError.unavailable }
            pcm.append(contentsOf: values)
        }
        guard reader.status != .failed, !pcm.isEmpty else { throw AnalysisError.unavailable }
        return BeatOnsetAnalysis.onsets(samples: pcm, sampleRate: 11_025, offset: start)
    }
}
