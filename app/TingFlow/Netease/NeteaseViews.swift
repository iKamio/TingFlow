import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit
import Photos

@MainActor struct NeteaseAccountView: View {
    @ObservedObject var store: NeteaseStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var qrImage: UIImage?
    @State private var savingQR = false
    @State private var photoMessage = ""

    var body: some View {
        Form {
            Section("网易云音乐 · 原生实验接入") {
                Text("使用社区接口直连网易云，不是官方开放平台授权。接口可能变化或触发风控；仅在你主动扫码确认后保存本机登录凭据。")
                    .font(.footnote).foregroundStyle(.secondary)
                Label(store.accountName, systemImage: store.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                if store.isSignedIn {
                    Button("刷新身份与歌单") { Task { await store.refresh() } }
                        .disabled(store.isLoading)
                    Button("退出并清除此机凭据", role: .destructive) { Task { await store.signOut() } }
                    Text("退出会清除本应用的凭据与元数据缓存，不会退出其他设备，也不保证撤销平台服务端会话。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(store.isAuthorizing ? "重新生成二维码" : "我同意，开始扫码登录") { store.beginQRCodeLogin() }
                        .disabled(store.isLoading)
                    Text("一部手机也可尝试：保存二维码 → 网易云 App 的扫一扫 → 选择相册图片 → 确认后返回听流。是否接受图库二维码取决于官方 App；打开 App 不等于登录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.isAuthorizing || !store.qrStatus.isEmpty {
                Section("扫码登录") {
                    if let qrImage {
                        HStack {
                            Spacer()
                            Image(uiImage: qrImage).interpolation(.none).resizable()
                                .scaledToFit().frame(width: 220, height: 220)
                                .padding(12).background(Color.white)
                                .accessibilityLabel("网易云短期登录二维码，请用官方 App 扫码")
                                .privacySensitive()
                            Spacer()
                        }
                        Button(savingQR ? "正在保存…" : "保存二维码到相册") { Task { await saveQRCode() } }
                            .disabled(savingQR || !store.canResumeQRCode)
                        Button("打开网易云 App") {
                            UIApplication.shared.open(URL(string: "orpheus://")!, options: [:]) { opened in
                                if !opened { photoMessage = "系统未能打开网易云，请手动进入官方 App 的扫一扫。" }
                            }
                        }
                        Text("仅向相册添加这张二维码，不读取你的相册。二维码用于短期登录，不要发给他人。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if store.isAuthorizing { ProgressView() }
                    Text(store.qrStatus).font(.callout)
                    if !photoMessage.isEmpty { Text(photoMessage).font(.footnote).foregroundStyle(.secondary) }
                    if store.isAuthorizing {
                        Button("返回后继续核验") { store.resumeQRCodeLogin() }.disabled(!store.canResumeQRCode)
                        Button("取消扫码", role: .cancel) { store.cancelQRCodeLogin() }
                        Text("最多轮询 60 次 / 3 分钟；切换 App 暂停，返回后继续；关闭登录页或过期才取消。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if store.isLoading { ProgressView("正在核验账号…") }
            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    if !store.isSignedIn && !store.isAuthorizing {
                        Button("重试清除此机凭据", role: .destructive) { Task { await store.signOut() } }
                    }
                }
            }
        }
        .navigationTitle("网易云账号")
        .task { await store.refresh() }
        .onChange(of: store.qrURL) { qrImage = Self.makeQR($0); photoMessage = "" }
        .onChange(of: scenePhase) {
            if $0 == .active { store.resumeQRCodeLogin() } else { store.pauseQRCodeLogin() }
        }
        .onDisappear {
            // Switching apps is not dismissal of the login page.
            if scenePhase == .active { store.cancelQRCodeLogin(); qrImage = nil }
        }
    }

    private func saveQRCode() async {
        guard let image = qrImage, let originalURL = store.qrURL, store.canResumeQRCode else { return }
        savingQR = true
        defer { savingQR = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            photoMessage = "未获得添加照片权限；你也可以截取二维码再从网易云的相册扫一扫识别。"
            return
        }
        guard store.qrURL == originalURL, store.canResumeQRCode else { photoMessage = "二维码已过期，请重新生成后保存。"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            photoMessage = "已保存；请在网易云的扫一扫中选择这张图片，确认后返回听流。"
        } catch { photoMessage = "保存未完成，可截图二维码使用；请勿向他人分享登录二维码。" }
    }

    private static func makeQR(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor struct NeteaseLibraryView: View {
  @ObservedObject var store: NeteaseStore
  let onPlay: ([Song], Int) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var contentID = UUID()
  init(store: NeteaseStore, onPlay: @escaping ([Song], Int) -> Void) { self.store = store; self.onPlay = onPlay }
  private var playlists: [NeteasePlaylist] {
    guard store.isSignedIn, let scope = store.scopeID else { return [] }
    return store.playlists.filter { $0.accountScope == scope }
  }
  private var daily: some View { NeteaseDailySongsView(store: store, onPlay: onPlay) }
  private var mine: some View { NeteaseMyPlaylistsView(store: store, onPlay: onPlay) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        NavigationLink { NeteaseAccountView(store: store) } label: {
          tile(store.isSignedIn ? store.accountName : "登录网易云", store.isSignedIn ? "\(playlists.count) 张歌单" : "找回你的歌单与每日推荐", store.avatarURL, size: 44, symbol: "chevron.right")
        }.buttonStyle(.plain)
        if store.isSignedIn {
          NavigationLink { daily } label: {
            tile("每日推荐", "\(Date.now.formatted(date: .abbreviated, time: .omitted)) · \(store.dailySongs.count) 首", neteaseSongs(store.dailySongs, in: store).first?.artworkURL, size: 76, symbol: "play.circle.fill", loading: store.isLoadingRecommendations)
          }.buttonStyle(.plain)
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize > .large ? 1 : 2), spacing: 12) {
            NavigationLink { daily } label: { module("每日歌曲", "calendar") }
            NavigationLink { NeteaseRecommendationsView(store: store, kind: .daily, onPlay: onPlay) } label: { module("每日歌单", "square.grid.2x2") }
            NavigationLink { mine } label: { module("我的歌单", "music.note.list") }
            NavigationLink { NeteaseFMView(store: store, onPlay: onPlay) } label: { module("私人 FM", "dot.radiowaves.left.and.right") }
          }.buttonStyle(.plain)
          HStack {
            Text("我的歌单").font(.headline)
            Spacer()
            NavigationLink { mine } label: { Text("查看全部").font(.subheadline).frame(minHeight: 44) }.tint(.pink)
          }
          NeteaseLoadState(title: "歌单", loading: store.isLoading && playlists.isEmpty, error: store.errorMessage, empty: playlists.isEmpty)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
              ForEach(Array(playlists.prefix(6).enumerated()), id: \.offset) { _, playlist in
                NavigationLink { NeteasePlaylistView(store: store, playlist: playlist, onPlay: onPlay) } label: {
                  NeteasePlaylistCard(playlist: playlist).frame(width: typeSize > .large ? 150 : 112)
                }.buttonStyle(.plain)
              }
            }
          }
        } else { NeteaseLoadState(title: "账号", loading: store.isLoading, error: store.errorMessage, empty: false) }
      }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
    .id(contentID).background(Color(uiColor: .systemGroupedBackground)).navigationTitle("网易云")
    .task { await store.refresh() }
    .refreshable { await store.refresh() }
    .onChange(of: store.scopeID) { _ in contentID = UUID() }
  }
  private func tile(_ title: String, _ caption: String, _ url: URL?, size: CGFloat, symbol: String, loading: Bool = false) -> some View {
    HStack(spacing: 12) {
      ArtworkView(url: url, corner: size == 44 ? 22 : 12).frame(width: size, height: size)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
        Text(caption).font(.caption).foregroundStyle(.secondary)
        if loading { ProgressView().controlSize(.small) }
      }
      Spacer(minLength: 0)
      Image(systemName: symbol).foregroundStyle(.pink)
    }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
  }
  private func module(_ title: String, _ symbol: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.title3).foregroundStyle(.pink).frame(width: 26)
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
      Spacer(minLength: 0)
    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12)
      .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
  }
}

@MainActor struct NeteasePlaylistView: View {
  @ObservedObject var store: NeteaseStore
  let playlist: NeteasePlaylist
  let onPlay: ([Song], Int) -> Void
  private typealias Loader = NeteasePlaylistLoadController<Song>
  @StateObject private var loader = NeteasePlaylistLoadController<Song>()
  private var isCurrent: Bool { store.isSignedIn && store.scopeID == playlist.accountScope }
  private var loadIdentity: Loader.Identity {
    Loader.Identity(playlistID: playlist.id, accountScope: playlist.accountScope,
                    sessionScope: store.scopeID, signedIn: store.isSignedIn)
  }
  private var caption: String {
    [playlist.ownerName, playlist.isPrivate ? "私密歌单" : "", playlist.isLiked ? "我喜欢的音乐" : "", "\(playlist.trackCount) 首"].filter { !$0.isEmpty }.joined(separator: " · ")
  }
  var body: some View {
    List {
      if isCurrent {
        NeteaseCoverHeader(title: playlist.name, caption: caption, url: playlist.coverURL)
        NeteaseCloudPlaylistButton(store: store, playlist: playlist)
        loadStatus
        NeteaseTrackList(store: store, songs: loader.items, onPlay: onPlay)
      } else { NeteasePageMessage(title: "请重新选择歌单", detail: "账号已变化，请返回歌单页。") }
    }
    .listStyle(.plain).navigationTitle("歌单").navigationBarTitleDisplayMode(.inline)
    // No SwiftUI task owns the request. Restart/cancellation of .task/.refreshable
    // cannot clear a newer result or strand a loading flag.
    .onAppear { beginLoad(automatic: true) }
    .onChange(of: loadIdentity) { _ in beginLoad(automatic: true) }
    .refreshable { if !loader.isLoading { beginLoad(automatic: false) } }
    .onDisappear { loader.cancel() }
  }
  @ViewBuilder private var loadStatus: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch loader.phase {
      case .loading:
        ProgressView("正在读取歌单歌曲…").accessibilityIdentifier("playlist-load-spinner")
        Text("已等待 \(loader.elapsedSeconds) 秒 · 最长 \(Int(loader.deadlineSeconds)) 秒")
          .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("playlist-load-progress")
        Text("歌单标记 \(loader.expectedCount) 首 · 已保留 \(loader.items.count) 首。详情读取完成后统一显示。")
          .font(.caption).foregroundStyle(.secondary)
        Button("取消读取", role: .cancel) { loader.cancel() }
          .accessibilityIdentifier("playlist-load-cancel").frame(minHeight: 44)
      case .failed(let reason):
        Text(reason.message).foregroundStyle(.red).accessibilityIdentifier("playlist-load-error")
        retainedSongs
        retryButton
      case .cancelled:
        Text("读取已取消；不会自动重试。").accessibilityIdentifier("playlist-load-cancelled")
        retainedSongs
        retryButton
      case .loaded:
        Text(loader.items.isEmpty ? "暂无歌单歌曲" : "已读取 \(loader.items.count) 首歌单歌曲")
          .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("playlist-load-complete")
      case .idle:
        Text("尚未读取歌单歌曲").font(.footnote).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 6)
  }
  private var retainedSongs: some View {
    Text(loader.items.isEmpty ? "尚未取得歌曲。不会自动重试，也不会使用示例数据。" : "已保留上次读取的 \(loader.items.count) 首歌曲，可继续浏览。不会自动重试。")
      .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("playlist-load-retained")
  }
  private var retryButton: some View {
    Button("重试读取") { beginLoad(automatic: false) }
      .accessibilityIdentifier("playlist-load-retry").frame(minHeight: 44)
  }
  private func beginLoad(automatic: Bool) {
    // Capture only the store and immutable playlist, never the view/controller in its worker.
    let store = store, playlist = playlist
    let operation: Loader.Operation = { try await store.tracks(in: playlist) }
    let current: Loader.Validator = { store.isSignedIn && store.scopeID == playlist.accountScope }
    if automatic {
      loader.appear(identity: loadIdentity, expectedCount: playlist.trackCount,
                    operation: operation, isCurrent: current, failure: Self.loadFailure)
    } else {
      loader.load(identity: loadIdentity, expectedCount: playlist.trackCount,
                  operation: operation, isCurrent: current, failure: Self.loadFailure)
    }
  }
  private static func loadFailure(_ error: Error) -> Loader.Failure {
    // Never display localizedDescription, request URLs, account/song IDs, or cookies.
    guard let error = error as? NeteaseError else { return .other }
    switch error {
    case .network, .transientNetwork: return .network
    case .verification: return .verification
    case .rateLimited: return .rateLimited
    case .signedOut, .identity: return .signedOut
    case .response, .incomplete: return .invalidData
    case .rejected, .business, .http: return .rejected
    default: return .other
    }
  }
}
