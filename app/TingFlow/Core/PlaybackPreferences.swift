import Foundation
import Combine

@MainActor final class PlaybackPreferences: ObservableObject {
    static let qualityKey = "tingflow.playback.requested-quality"
    @Published var quality: AudioQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey) }
    }
    @Published var playbackMode: NeteasePlaybackMode {
        didSet { UserDefaults.standard.set(playbackMode.rawValue, forKey: "tingflow.netease.playback-mode") }
    }
    @Published var useSources: Bool {
        didSet { UserDefaults.standard.set(useSources, forKey: "tingflow.playback.user-sources") }
    }
    @Published var minimizeTabBar: Bool {
        didSet { UserDefaults.standard.set(minimizeTabBar, forKey: "tingflow.ui.minimize-tab-bar") }
    }
    init() {
        quality = AudioQuality(rawValue: UserDefaults.standard.string(forKey: Self.qualityKey) ?? "") ?? .high
        playbackMode = NeteasePlaybackMode(rawValue: UserDefaults.standard.string(forKey: "tingflow.netease.playback-mode") ?? "") ?? .nativeV1
        useSources = UserDefaults.standard.object(forKey: "tingflow.playback.user-sources") as? Bool ?? true
        minimizeTabBar = UserDefaults.standard.object(forKey: "tingflow.ui.minimize-tab-bar") as? Bool ?? true
    }
}
