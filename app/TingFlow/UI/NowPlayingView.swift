import SwiftUI
import AVKit
import MediaPlayer

struct MiniPlayerView: View {
    @ObservedObject var player: PlayerStore
    let open: () -> Void
    var body: some View {
        if #available(iOS 26.0, *) { AdaptiveMiniPlayer(player: player, open: open) }
        else { MiniPlayerContent(player: player, compact: false, open: open) }
    }
}

@available(iOS 26.0, *) private struct AdaptiveMiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @ObservedObject var player: PlayerStore
    let open: () -> Void
    var body: some View { MiniPlayerContent(player: player, compact: placement == .inline, open: open) }
}

private struct MiniPlayerContent: View {
    @ObservedObject var player: PlayerStore
    let compact: Bool
    let open: () -> Void
    var body: some View {
        HStack(spacing: compact ? 5 : 10) {
            Button(action: open) {
                HStack(spacing: 9) {
                    ArtworkView(url: player.current?.displayArtworkURL, corner: compact ? 5 : 7)
                        .frame(width: compact ? 28 : 38, height: compact ? 28 : 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.current?.title ?? "听流").font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !compact { Text(player.isLoading ? "正在连接…" : (player.current?.artist ?? "选择一首音乐开始"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(player.current == nil).accessibilityLabel("展开播放器")
            Button { player.toggle() } label: {
                Group { if player.isLoading { ProgressView() }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.headline) }
                }.frame(width: 38, height: 44)
            }.buttonStyle(.plain).disabled(player.current == nil || player.isLoading).accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            if !compact {
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.headline).frame(width: 40, height: 44) }
                    .buttonStyle(.plain).disabled(player.current == nil).accessibilityLabel("下一首")
            }
        }.padding(.horizontal, compact ? 6 : 12).frame(minHeight: compact ? 44 : 54)
    }
}

struct PlayerTransitionSource: ViewModifier {
    let namespace: Namespace.ID
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled { content.matchedTransitionSource(id: "tingflow-player", in: namespace) }
        else { content }
    }
}
struct PlayerSheetTransition: ViewModifier {
    let namespace: Namespace.ID
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled { content.navigationTransition(.zoom(sourceID: "tingflow-player", in: namespace)) }
        else { content }
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var preferences: PlaybackPreferences
    @ObservedObject var player: PlayerStore
    @ObservedObject var library: LibraryStore
    @ObservedObject var netease: NeteaseStore
    private enum Panel { case artwork, lyrics, queue }
    @State private var panel = Panel.artwork
    @State private var lyrics: [LyricLine] = []
    @State private var lyricMessage = ""
    @State private var lyricPlainText = ""
    @State private var lyricSource = ""
    @State private var lyricRetry = 0
    @State private var lyricGeneration = UUID()
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @State private var showSongComments = false
    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.height < 620 || typeSize.isAccessibilitySize {
                    ScrollView { content(height: 860).frame(width: geometry.size.width, alignment: .top) }
                } else {
                    content(height: geometry.size.height).frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background {
                GeometryReader { backdrop in
                    ambientBackground.frame(width: backdrop.size.width, height: backdrop.size.height).clipped()
                }.ignoresSafeArea()
            }
        }
        .tint(.primary)
        .task(id: "\(player.current?.id ?? ""):\(lyricRetry)") { await loadLyrics() }
        .onChange(of: player.current?.id) { _ in scrubbing = false }
        .sheet(isPresented: $showSongComments) {
            if let song = player.current, song.platform == .netease {
                SongCommentsView(song: song).environmentObject(netease)
            }
        }
    }
    /// Restrict pull-to-close to the header/cover, never lyric/queue scroll views or sliders.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let delta = value.translation
                let projected = value.predictedEndTranslation
                guard delta.height > 36, delta.height > abs(delta.width) * 1.5,
                      delta.height > 90 || projected.height > 180 else { return }
                dismiss()
            }
    }
    private var ambientBackground: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if !reduceTransparency, let image = player.artworkImage {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 65)
                    .opacity(scheme == .dark ? 0.40 : 0.24).clipped()
                Color(uiColor: .systemBackground).opacity(scheme == .dark ? 0.30 : 0.42)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func content(height: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 38) }
                    .accessibilityLabel("收起播放器")
                Spacer()
                Text(player.sourceLabel.isEmpty ? (player.current?.platform.title ?? "听流") : player.sourceLabel)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    if let song = player.current {
                        Button(library.isFavorite(song) ? "取消本机收藏" : "仅收藏到本机") { library.toggleFavorite(song) }
                    }
                    Picker("请求音质（下一首生效）", selection: $preferences.quality) {
                        ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 38) }.accessibilityLabel("播放选项")
            }
            .contentShape(Rectangle())
            .simultaneousGesture(dismissGesture)
            upperPanel(height: max(220, height - 336))
            controlPanel
        }.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 18)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
    }
    @ViewBuilder private func upperPanel(height: CGFloat) -> some View {
        VStack(spacing: 16) {
            if panel == .artwork {
                Spacer(minLength: 0)
                ArtworkView(url: player.current?.displayArtworkURL, corner: 16)
                    .aspectRatio(1, contentMode: .fit).frame(maxWidth: min(410, max(180, height - 100)))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.12), radius: 22, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.93)
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9), value: player.isPlaying)
                    .contentShape(Rectangle())
                    .simultaneousGesture(dismissGesture)
                Spacer(minLength: 0)
                trackHeading(compact: false)
            } else {
                trackHeading(compact: true)
                if panel == .lyrics { lyricPanel }
                else { queuePanel }
            }
        }.frame(height: height)
    }
    private func trackHeading(compact: Bool) -> some View {
        HStack(spacing: 12) {
            if compact { ArtworkView(url: player.current?.displayArtworkURL, corner: 7).frame(width: 48, height: 48) }
            VStack(alignment: .leading, spacing: 5) {
                Text(player.current?.title ?? "尚未播放").font(compact ? .headline : .title2.weight(.bold)).lineLimit(2)
                Text(player.current?.artist ?? "").font(compact ? .subheadline : .title3).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let song = player.current {
                if song.platform == .netease {
                    Button { showSongComments = true } label: {
                        Image(systemName: "text.bubble").font(.title3).frame(width: 40, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("歌曲评论")
                        .accessibilityIdentifier("song-comments-open")
                    NeteaseCloudLikeButton(store: netease, song: song)
                    NeteaseCloudSongMenu(store: netease, song: song)
                } else {
                    Button { library.toggleFavorite(song) } label: {
                        Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart")
                            .font(.title3).foregroundStyle(library.isFavorite(song) ? Color.pink : .primary).frame(width: 44, height: 44)
                    }.accessibilityLabel(library.isFavorite(song) ? "取消本机收藏" : "本机收藏")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var controlPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                Slider(value: Binding(get: { scrubbing ? scrub : min(max(0, player.elapsed), max(1, player.duration)) }, set: { scrub = $0 }),
                       in: 0...max(1, player.duration), onEditingChanged: { editing in
                    if editing { scrub = player.elapsed; scrubbing = true }
                    else { player.seek(to: scrub); scrubbing = false }
                }).disabled(player.duration <= 0 || player.isLoading).accessibilityLabel("播放进度")
                HStack(spacing: 6) {
                    Text(time(scrubbing ? scrub : player.elapsed)).monospacedDigit()
                    Spacer(minLength: 0)
                    Menu {
                        Text("当前：\(player.qualityLabel)")
                        Picker("下一首请求音质", selection: $preferences.quality) {
                            Text("标准 128k").tag(AudioQuality.standard)
                            Text("高品质 320k").tag(AudioQuality.high)
                            Text("无损 FLAC").tag(AudioQuality.lossless)
                        }
                        Text("以平台实际返回为准")
                    } label: {
                        Text(player.qualityLabel).lineLimit(1).font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }.accessibilityLabel("当前音质与下一首音质设置")
                    Spacer(minLength: 0)
                    Text("−" + time(max(0, player.duration - (scrubbing ? scrub : player.elapsed)))).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !player.transitionStatus.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                    Text(player.transitionStatus).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("playback-transition-status")
            }
            HStack {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 64, height: 58) }
                    .accessibilityLabel("上一首")
                Spacer()
                Button { player.toggle() } label: {
                    Group { if player.isLoading { ProgressView().controlSize(.large) }
                        else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 43, weight: .semibold)) }
                    }.frame(width: 72, height: 64)
                }.disabled(player.current == nil || player.isLoading).accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 64, height: 58) }
                    .accessibilityLabel("下一首")
            }.buttonStyle(.plain).padding(.horizontal, 20)
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").font(.caption)
                SystemVolumeView().frame(height: 32).accessibilityLabel("系统音量")
                Image(systemName: "speaker.wave.3.fill").font(.caption)
            }.foregroundStyle(.secondary)
            HStack {
                panelButton(.lyrics, symbol: "quote.bubble", label: "歌词")
                Spacer()
                VStack(spacing: 1) {
                    AirPlayButton().frame(width: 48, height: 34)
                    Text("音频输出").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                panelButton(.queue, symbol: "list.bullet", label: "待播列表")
            }.padding(.horizontal, 12)
            if let error = player.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
    }
    private func panelButton(_ value: Panel, symbol: String, label: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { panel = panel == value ? .artwork : value }
        } label: {
            Image(systemName: symbol).font(.title3).frame(width: 48, height: 44)
                .background(panel == value ? Color.primary.opacity(0.10) : .clear, in: Circle())
        }.accessibilityLabel(label).accessibilityValue(panel == value ? "已展开" : "未展开")
            .accessibilityIdentifier(value == .lyrics ? "player-lyrics" : "player-queue")
    }
    private var activeLine: Int? { lyrics.last(where: { $0.time <= player.elapsed })?.id }
    private var lyricPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !lyricSource.isEmpty {
                    Text(lyricSource).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                }
                if !lyricPlainText.isEmpty {
                    Text(lyricPlainText).font(.title3).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 26)
                } else if lyrics.isEmpty {
                    VStack(spacing: 18) {
                        Text(lyricMessage.isEmpty ? "此来源暂无歌词" : lyricMessage).font(.title3).foregroundStyle(.secondary)
                        if !lyricMessage.contains("正在读取"), player.current != nil {
                            Button("重试歌词") { lyricRetry += 1 }.accessibilityIdentifier("lyrics-retry")
                        }
                    }.frame(maxWidth: .infinity).padding(.top, 65)
                } else {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(lyrics) { line in
                            Button { player.seek(to: line.time) } label: {
                                Text(line.text.isEmpty ? "♪" : line.text).font(.title2.bold())
                                    .foregroundStyle(line.id == activeLine ? Color.primary : Color.secondary.opacity(0.65))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).id(line.id)
                        }
                    }.padding(.vertical, 55)
                }
            }.onChange(of: activeLine) { id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
    private var queuePanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { player.shuffle.toggle() } label: {
                    Label("随机", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 42)
                        .background(player.shuffle ? Color.primary.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                }.accessibilityValue(player.shuffle ? "开启" : "关闭")
                Button { player.repeatMode = player.repeatMode.next } label: {
                    Label(player.repeatMode == .one ? "单曲循环" : (player.repeatMode == .all ? "列表循环" : "顺序"), systemImage: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .frame(maxWidth: .infinity, minHeight: 42).background(.primary.opacity(0.06), in: Capsule())
                }
            }.font(.subheadline).buttonStyle(.plain)
            HStack { Text("播放队列").font(.subheadline.weight(.semibold)); Spacer(); Text("\(player.queue.count) 首").font(.caption).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { index, song in
                            Button { player.play(player.queue, at: index) } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(url: song.displayArtworkURL, corner: 6).frame(width: 40, height: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.title).font(.subheadline.weight(index == player.index ? .semibold : .regular)).lineLimit(1)
                                        Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 3)
                                    if index == player.index { Image(systemName: "waveform").foregroundStyle(.pink) }
                                }.padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                        }
                    }
                }.onAppear { proxy.scrollTo(max(0, player.index), anchor: .top) }
            }
        }
    }
    private func loadLyrics() async {
        let token = UUID(); lyricGeneration = token
        lyrics = []; lyricMessage = ""; lyricPlainText = ""; lyricSource = ""
        #if DEBUG
        if UIPolishFixture.enabled {
            lyrics = LRCParser.parse("[00:00]沿着海岸慢慢走\n[00:12]听风把故事带走\n[00:25]这一刻只想听见音乐\n[00:40]原生界面测试歌词")
            return
        }
        #endif
        guard let song = player.current else { return }
        guard [.netease, .emby, .subsonic].contains(song.platform) else {
            lyricMessage = "此来源尚未提供歌词。"; return
        }
        lyricMessage = "正在读取歌词…"
        do {
            let text: String
            if song.platform == .netease { text = try await netease.lyrics(for: song) }
            else { text = try await ExternalMetadata.shared.lyrics(for: song) }
            try Task.checkCancellation()
            guard player.current?.id == song.id, lyricGeneration == token else { return }
            lyrics = LRCParser.parse(text)
            if lyrics.isEmpty { lyricPlainText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            lyricSource = song.platform == .netease ? "网易云歌词" : "外部歌词 · api.lrc.cx · 按歌名与歌手匹配，版本可能不同"
            lyricMessage = lyrics.isEmpty && lyricPlainText.isEmpty ? "暂无可用歌词。" : ""
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, player.current?.id == song.id, lyricGeneration == token else { return }
            lyricMessage = (error as? ExternalMetadataFailure)?.localizedDescription ?? "歌词暂时不可用，请重试。"
        }
    }
    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(min(value, 864_000)); return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false; view.showsVolumeSlider = true
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) { }
}
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label; view.activeTintColor = .systemPink
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
