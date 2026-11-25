#if DEBUG
import SwiftUI
import UIKit

/// Isolated synthetic geometry fixture. No server account, URL or Keychain access.
/// This file and launch switch are absent from the Release binary.
@MainActor struct ServerArtworkPreviewFixture: View {
    @State private var scope: String? = "synthetic-cover-scope"
    private let titles = ["晚风歌单", "把漫长旅途与温柔心事都写进这一张歌单的夜晚", "没有服务器封面的歌单", "纵向封面专辑"]
    private func info(_ index: Int) -> ServerCollectionInfo {
        ServerCollectionInfo(service: "fixture", kind: index == 3 ? .album : .playlist,
            id: String(index), title: titles[index], artist: index == 3 ? "合成测试艺术家" : nil,
            songCount: index == 2 ? nil : 12, accountScope: "synthetic-cover-scope", artworkVersion: "synthetic-v1")
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
    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<4) { index in
                    NavigationLink {
                        List {
                            Section {
                                ServerCollectionHeader(collection: info(index), scope: scope) { pixels in
                                    try await image(index, pixels: pixels)
                                }
                            }
                            Text("仅用于封面布局验证，不是用户歌单或真实播放结果。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .navigationTitle(info(index).title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                            Button("退出测试账户") { scope = nil }.accessibilityIdentifier("serverCoverFixture.signOut")
                        } }
                    } label: {
                        ServerCollectionRow(collection: info(index), scope: scope) { pixels in
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
