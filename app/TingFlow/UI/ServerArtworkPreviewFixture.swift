#if DEBUG
import SwiftUI
import UIKit

/// Isolated synthetic geometry fixture. No server account, URL or Keychain access.
/// This file and launch switch are absent from the Release binary.
@MainActor struct ServerArtworkPreviewFixture: View {
    @State private var scope: String? = "synthetic-cover-scope"
    @State private var attempts: [String: Int] = [:]
    @State private var retryCompletions = 0
    @State private var delayedSignOut: Task<Void, Never>?
    // The app's existing outer -TingFlowServerCoverFixture gate is required.
    // The new switch alone cannot enter this isolated DEBUG fixture.
    private let diagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("-TingFlowServerCoverDiagnosticFixture")
    private var titles: [String] {
        diagnosticsEnabled
            ? ["接口权限错误（合成）", "未找到封面（合成）", "缩略图解码失败（合成）", "重试与取消隔离（合成）"]
            : ["晚风歌单", "把漫长旅途与温柔心事都写进这一张歌单的夜晚", "没有服务器封面的歌单", "纵向封面专辑"]
    }
    private func info(_ index: Int) -> ServerCollectionInfo {
        ServerCollectionInfo(service: "fixture", kind: index == 3 ? .album : .playlist,
            id: String(index), title: titles[index], artist: index == 3 ? "合成测试艺术家" : nil,
            songCount: index == 2 ? nil : 12, accountScope: "synthetic-cover-scope",
            artworkVersion: diagnosticsEnabled ? "synthetic-cover-secret-id" : "synthetic-v1")
    }
    private func image(_ index: Int, pixels: Int) async throws -> Data? {
        try Task.checkCancellation()
        if index == 2 { return nil }
        let size: CGSize
        switch index {
        case 1: size = CGSize(width: 900, height: 300)
        case 3: size = CGSize(width: 320, height: 800)
        default: size = CGSize(width: 500, height: 500)
        }
        let colors: [UIColor] = [.systemTeal, .systemIndigo, .systemGray, .systemOrange]
        return UIGraphicsImageRenderer(size: size).image { context in
            colors[index].setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.3).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.15, y: size.height * 0.15,
                                       width: size.width * 0.7, height: size.height * 0.7)).fill()
        }.pngData()
    }
    private func diagnosticLoader(_ index: Int) -> (@MainActor (Int) async throws -> ServerArtworkResult)? {
        guard diagnosticsEnabled else { return nil }
        return { pixels in try await diagnosticResult(index, pixels: pixels) }
    }
    private func diagnosticResult(_ index: Int, pixels: Int) async throws -> ServerArtworkResult {
        try Task.checkCancellation()
        // Row and header sizes have independent attempts, just like real requests.
        let key = "\(index):\(pixels)"
        let attempt = (attempts[key] ?? 0) + 1
        attempts[key] = attempt
        var diagnostic = ServerArtworkDiagnostic(service: .navidrome, pixels: pixels)
        diagnostic.httpStatus = 200
        if index == 0 || index == 1 || (index == 3 && (pixels <= 320 || !attempt.isMultiple(of: 2))) {
            let code = index == 1 ? 70 : 50
            diagnostic.stage = .api; diagnostic.issue = ServerArtworkDiagnostic.apiIssue(code)
            diagnostic.apiStatus = .failed; diagnostic.apiCode = code; diagnostic.mime = .json
            let envelope = Data("{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"code\":\(code)}}}".utf8)
            diagnostic.bytesReceived = envelope.count; diagnostic.expectedBytes = Int64(envelope.count)
            if index == 1 { return ServerArtworkResult(data: nil, diagnostic: diagnostic) }
            throw ServerArtworkDiagnosticFailure(diagnostic: diagnostic)
        }
        let data: Data?
        if index == 2 {
            // Valid PNG container, deliberately outside the existing UI width
            // guard. Exercise thumbnail(nil) without bypassing any safety limit.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = CGSize(width: 16_385, height: 1)
            data = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.systemPurple.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }.pngData()
        } else {
            data = try await image(0, pixels: pixels)
            // A finite, intentionally non-cooperative local callback lets UI tests
            // prove cancelled late bytes cannot restore the old account's result.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { continuation.resume() }
            }
            retryCompletions += 1
        }
        diagnostic.stage = .completed; diagnostic.mime = .png; diagnostic.imageFormat = .png
        diagnostic.bytesReceived = data?.count ?? 0
        diagnostic.expectedBytes = data.map { Int64($0.count) }
        return ServerArtworkResult(data: data, diagnostic: diagnostic)
    }
    private func scheduleSignOut() {
        delayedSignOut?.cancel()
        delayedSignOut = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            scope = nil
        }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<4) { index in
                    NavigationLink {
                        List {
                            Section {
                                ServerCollectionHeader(collection: info(index), scope: scope,
                                                       diagnosticLoad: diagnosticLoader(index),
                                                       diagnosticService: diagnosticsEnabled ? .navidrome : nil) { pixels in
                                    try await image(index, pixels: pixels)
                                }
                            }
                            Text("仅用于封面布局验证，不是用户歌单或真实播放结果。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if diagnosticsEnabled {
                                Text("合成重试完成：\(retryCompletions)")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("serverCoverFixture.retryCompletion")
                            }
                        }
                        .navigationTitle(info(index).title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("退出测试账户") { scope = nil }.accessibilityIdentifier("serverCoverFixture.signOut")
                            }
                            if diagnosticsEnabled {
                                ToolbarItem(placement: .bottomBar) {
                                    Button("15 秒后退出测试账户") { scheduleSignOut() }
                                        .accessibilityIdentifier("serverCoverFixture.signOutAfterDelay")
                                }
                            }
                        }
                    } label: {
                        ServerCollectionRow(collection: info(index), scope: scope,
                                            diagnosticLoad: diagnosticLoader(index),
                                            diagnosticService: diagnosticsEnabled ? .navidrome : nil) { pixels in
                            try await image(index, pixels: pixels)
                        }
                    }
                    .accessibilityIdentifier("serverCoverFixture.row.\(index)")
                }
            }
            .listStyle(.plain).navigationTitle("封面布局测试")
        }
    }
}
#endif
