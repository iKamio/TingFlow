#if DEBUG
import SwiftUI

/// Only compiled into simulator/debug builds. Never present in the delivered Release IPA.
@MainActor enum UIPolishFixture {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-TingFlowPolishFixture") || arguments.contains("-TingFlowSearchFixture")
    }
    static let scope = "netease:700001"
    static let covers = ["a", "b", "c", "d", "e", "f"]
    static func url(_ key: String) -> URL { URL(string: "https://p1.music.126.net/ui-test/\(key).jpg")! }
    static func image(_ url: URL) -> UIImage? {
        guard enabled, url.host == "p1.music.126.net", url.path.hasPrefix("/ui-test/") else { return nil }
        let key = url.deletingPathExtension().lastPathComponent
        let index = covers.firstIndex(of: key) ?? 0
        let colors: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange, .systemPink, .systemGreen, .systemBlue]
        // Keep cover a (the current-track/player fixture) unchanged. The same
        // real card grid now exercises landscape, missing and portrait artwork.
        let size: CGSize
        switch key {
        case "b": size = CGSize(width: 960, height: 480)
        case "d": size = CGSize(width: 360, height: 900)
        default: size = CGSize(width: 600, height: 600)
        }
        return UIGraphicsImageRenderer(size: size).image { context in
            colors[index].setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.14).setFill()
            UIBezierPath(ovalIn: CGRect(x: -120, y: 30, width: 560, height: 560)).fill()
            UIColor.black.withAlphaComponent(0.15).setFill()
            UIBezierPath(ovalIn: CGRect(x: 220, y: -80, width: 520, height: 520)).fill()
            let text = ["FLOW", "NIGHT", "AFTER", "MUSIC", "BLOOM", "BLUE"][index]
            (text as NSString).draw(at: CGPoint(x: 44, y: 440), withAttributes: [.font: UIFont.systemFont(ofSize: 72, weight: .heavy), .foregroundColor: UIColor.white])
        }
    }
    static var songs: [Song] {
        ["海风来信", "夜行者", "慢慢靠岸", "我们的晴天", "让花盛开", "蓝色时刻"].enumerated().map { index, title in
            Song(platform: .netease, platformID: "\(index + 1)", title: title, artist: "听流测试音乐", album: "原生界面测试", duration: 246,
                 artworkURL: url(covers[index]), accountScope: scope)
        }
    }
    static var playlists: [NeteasePlaylist] {
        ["留给晚风的歌", "夜幕降临后把所有漫长旅途和温柔心事都写进这张歌单", "我的轻松时刻", "晴天漫游", "我喜欢的音乐", "长路与蓝色"].enumerated().map { index, name in
            NeteasePlaylist(id: "\(index + 100)", name: name, trackCount: 6, coverURL: index == 2 ? nil : url(covers[index]), ownerName: "听流测试账号", accountScope: scope,
                            ownerID: index < 3 ? "700001" : "700002", isPrivate: index == 0, isLiked: index == 4)
        }
    }
}
#endif


#if DEBUG
@MainActor enum SearchPolishFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-TingFlowSearchFixture") }
    static var songs: [Song] {
        [
            Song(platform: .netease, platformID: "990001", title: "海风来信", artist: "听流合成测试", album: "合成封面 A", duration: 190, artworkURL: UIPolishFixture.url("a")),
            Song(platform: .kugou, platformID: "990002", title: "夜行者", artist: "听流合成测试", album: "合成封面 B", duration: 205, artworkURL: UIPolishFixture.url("b")),
            Song(platform: .netease, platformID: "990003", title: "蓝色时刻", artist: "听流合成测试", album: "合成封面 C", duration: 215, artworkURL: UIPolishFixture.url("c"))
        ]
    }
}
#endif
