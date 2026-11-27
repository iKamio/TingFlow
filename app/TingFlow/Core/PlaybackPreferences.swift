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
    @Published var enhancedMatch: EnhancedMatchConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(enhancedMatch) {
                UserDefaults.standard.set(data, forKey: "tingflow.playback.enhanced-match")
            }
        }
    }
    @Published var minimizeTabBar: Bool {
        didSet { UserDefaults.standard.set(minimizeTabBar, forKey: "tingflow.ui.minimize-tab-bar") }
    }
    @Published var transitionSettings: PlaybackTransitionSettings {
        didSet { persistTransitionSettings() }
    }
    init() {
        quality = AudioQuality(rawValue: UserDefaults.standard.string(forKey: Self.qualityKey) ?? "") ?? .high
        playbackMode = NeteasePlaybackMode(rawValue: UserDefaults.standard.string(forKey: "tingflow.netease.playback-mode") ?? "") ?? .nativeV1
        useSources = UserDefaults.standard.object(forKey: "tingflow.playback.user-sources") as? Bool ?? true
        enhancedMatch = UserDefaults.standard.data(forKey: "tingflow.playback.enhanced-match")
            .flatMap { try? JSONDecoder().decode(EnhancedMatchConfiguration.self, from: $0) } ?? EnhancedMatchConfiguration()
        minimizeTabBar = UserDefaults.standard.object(forKey: "tingflow.ui.minimize-tab-bar") as? Bool ?? true
        transitionSettings = PlaybackTransitionSettings.load()
    }
    private func persistTransitionSettings() {
        let defaults = UserDefaults.standard
        defaults.set(transitionSettings.mode.rawValue, forKey: PlaybackTransitionSettings.modeKey)
        defaults.set(PlaybackTransitionSettings.boundedSeconds(transitionSettings.seconds), forKey: PlaybackTransitionSettings.durationKey)
        defaults.set(transitionSettings.curve.rawValue, forKey: PlaybackTransitionSettings.curveKey)
        NotificationCenter.default.post(name: PlaybackTransitionSettings.changed, object: nil)
    }
}
