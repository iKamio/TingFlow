import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var preferences: PlaybackPreferences
    @State private var matchAddress = ""
    @State private var matchMessage: String?
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
            Section("网易云匹配服务 · api-enhanced") {
                TextField("https://你的 API 域名", text: $matchAddress)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("enhanced-match-address")
                Button("保存服务地址") {
                    var next = preferences.enhancedMatch
                    next.address = matchAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        if next.address.isEmpty { next.enabled = false }
                        else { _ = try next.baseURL() }
                        preferences.enhancedMatch = next
                        matchAddress = next.address
                        matchMessage = next.address.isEmpty ? "已清除地址并关闭匹配。" : "地址已保存，尚未验证服务连通性。"
                    } catch { matchMessage = EnhancedMatchFailure.address.localizedDescription }
                }
                Picker("匹配模块", selection: $preferences.enhancedMatch.source) {
                    ForEach(EnhancedMatchSource.allCases) { source in Text(source.title).tag(source) }
                }
                Toggle("平台无完整音频时尝试匹配", isOn: Binding(
                    get: { preferences.enhancedMatch.enabled },
                    set: { enabled in
                        do {
                            if enabled { _ = try preferences.enhancedMatch.baseURL() }
                            preferences.enhancedMatch.enabled = enabled
                            matchMessage = nil
                        } catch { matchMessage = EnhancedMatchFailure.address.localizedDescription }
                    }
                )).accessibilityIdentifier("enhanced-match-enabled")
                if let matchMessage { Text(matchMessage).font(.footnote).foregroundStyle(.secondary) }
                Text("仅在网易云无音频或仅有试听时使用。自动选源先尝试已启用的脚本；手动选源保持你的选择。会向你配置的服务及其音源发送歌曲 ID，不发送网易云 Cookie。匹配版本与音质由服务决定，可能失败；仅使用你有权播放的来源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("曲目过渡") {
                Picker("过渡方式", selection: Binding(
                    get: { preferences.transitionSettings.mode },
                    set: { preferences.transitionSettings.mode = $0 }
                )) {
                    ForEach(PlaybackTransitionMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.accessibilityIdentifier("playback-transition-mode")
                Picker("淡化时长", selection: Binding(
                    get: { PlaybackTransitionSettings.boundedSeconds(preferences.transitionSettings.seconds) },
                    set: { preferences.transitionSettings.seconds = $0 }
                )) {
                    ForEach(1...8, id: \.self) { seconds in Text("\(seconds) 秒").tag(Double(seconds)) }
                }.disabled(preferences.transitionSettings.mode == .off)
                Picker("音量曲线", selection: Binding(
                    get: { preferences.transitionSettings.curve },
                    set: { preferences.transitionSettings.curve = $0 }
                )) {
                    ForEach(PlaybackTransitionCurve.allCases) { curve in Text(curve.title).tag(curve) }
                }.disabled(preferences.transitionSettings.mode == .off)
                Text("固定淡化默认 3 秒，由两个 AVPlayer 实际交叉调节音量；“本机起音对齐”只分析安全可读的本地 PCM，不推断 BPM、不拉取远程音频。远程、鉴权或样本不足时会显示固定淡化回退；直播、未知时长、短曲及单曲循环正常切歌。不是 Apple AutoMix。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("底部导航") {
                Toggle("滚动时收起底栏", isOn: $preferences.minimizeTabBar)
                    .accessibilityIdentifier("playback-minimize")
                Text("iOS 26 使用系统玻璃栏与内嵌播放器变形；低版本保留原生导航。开启“减少动态效果”时不触发额外视图动画。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("播放与界面")
            .onAppear { matchAddress = preferences.enhancedMatch.address }
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
