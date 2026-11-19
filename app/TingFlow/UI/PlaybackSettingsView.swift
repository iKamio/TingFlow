import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var preferences: PlaybackPreferences
    var body: some View {
        Form {
            Section("网易云播放模式") {
                Picker("请求方式", selection: $preferences.playbackMode) {
                    Text("原生高音质接口").tag(NeteasePlaybackMode.nativeV1)
                    Text("标准兼容 · 128 kbps").tag(NeteasePlaybackMode.legacyStandard)
                }.accessibilityIdentifier("playback-mode")
                Text("标准兼容使用之前已能播放的普通接口，每次只请求一次。切换设置不自动重播、不清除账号；下次主动点播才使用。验证或限流失败时不会自动改协议或换源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("播放音质") {
                Picker("请求音质", selection: $preferences.quality) {
                    Text("标准 · 128 kbps").tag(AudioQuality.standard)
                    Text("高品质 · 320 kbps").tag(AudioQuality.high)
                    Text("无损 · FLAC").tag(AudioQuality.lossless)
                }.disabled(preferences.playbackMode == .legacyStandard)
                Text("下一首开始使用新选择。网易云是否返回高品质取决于账号与曲目权限；播放页显示平台实际返回的格式和码率，不把请求无损当作已经无损。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("你添加的音源") {
                Toggle("平台无可用完整音频时尝试音源", isOn: $preferences.useSources)
                Text("仅运行你已信任并启用的脚本。网易云歌单与酷狗音源登录不是同一授权；没有酷狗账号不代表所有来源都失败，也不代表网易云会员能获得其它平台版权。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("未导入音源时，只播放平台实际提供的音频。跨平台匹配失败会明确提示，不用相似歌名替换你的歌曲。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("底部导航") {
                Toggle("滚动时收起底栏", isOn: $preferences.minimizeTabBar)
                    .accessibilityIdentifier("playback-minimize")
                Text("iOS 26 使用系统玻璃栏与内嵌播放器变形；低版本保留原生导航。开启“减少动态效果”时不触发额外视图动画。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("播放与界面")
    }
}

struct AccountAvatarView: View {
    let url: URL?
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let url { ArtworkView(url: url, corner: size / 2) }
            else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.pink) }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}
