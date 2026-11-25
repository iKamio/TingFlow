import SwiftUI
import UIKit
import ImageIO

// Collection artwork never passes authenticated URLs to the public ArtworkLoader.
// Only the account-scoped server store supplies bytes, and only visible views load.
enum ServerCollectionKind: String {
    case album, playlist
    var symbol: String { self == .playlist ? "music.note.list" : "opticaldisc" }
    var title: String { self == .playlist ? "歌单" : "专辑" }
}

struct ServerCollectionInfo {
    let service: String
    let kind: ServerCollectionKind
    let id: String
    let title: String
    let artist: String?
    let songCount: Int?
    let accountScope: String
    let artworkVersion: String?

    var artworkKey: String {
        // Length prefixes avoid collisions when server IDs contain punctuation.
        [service, kind.rawValue, id, artworkVersion ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
    var accessibilityID: String { "serverCollection.\(service).\(kind.rawValue).\(id)" }
    var metadata: String? {
        var parts: [String] = []
        if let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            parts.append(artist)
        }
        if let songCount, songCount >= 0 { parts.append("\(songCount) 首") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    func activeScope(_ scope: String?) -> String? { scope == accountScope ? scope : nil }
}

@MainActor struct ServerCollectionRow: View {
    let collection: ServerCollectionInfo
    let scope: String?
    let load: @MainActor (Int) async throws -> Data?

    var body: some View {
        HStack(spacing: 12) {
            ServerArtworkView(key: collection.artworkKey, scope: collection.activeScope(scope),
                              symbol: collection.kind.symbol, pixels: 180, size: 60,
                              accessibilityID: collection.accessibilityID + ".artwork", load: load)
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).foregroundStyle(.primary).lineLimit(2)
                if let metadata = collection.metadata {
                    Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

@MainActor struct ServerCollectionHeader: View {
    let collection: ServerCollectionInfo
    let scope: String?
    let load: @MainActor (Int) async throws -> Data?

    var body: some View {
        VStack(spacing: 12) {
            ServerArtworkView(key: collection.artworkKey, scope: collection.activeScope(scope),
                              symbol: collection.kind.symbol, pixels: 630, size: 210, corner: 18,
                              showsStatus: true,
                              accessibilityID: collection.accessibilityID + ".header.artwork", load: load)
            Text(collection.title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(collection.accessibilityID + ".header.title")
                .accessibilityAddTraits(.isHeader)
            if let metadata = collection.metadata {
                Text(metadata).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(collection.accessibilityID + ".header.metadata")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(collection.accessibilityID + ".header")
    }
}

private struct ServerArtworkRequest: Hashable {
    let key: String
    let scope: String?
    let pixels: Int
    let retry: Int
}

private enum ServerArtworkPhase: Equatable {
    case idle, loading, loaded, missing, failed
    var message: String {
        switch self {
        case .idle, .failed: return "封面暂未载入"
        case .loading: return "正在载入封面…"
        case .loaded: return "已载入服务器封面"
        case .missing: return "服务器未提供封面"
        }
    }
}

@MainActor struct ServerArtworkView: View {
    let key: String
    let scope: String?
    let symbol: String
    let pixels: Int
    var size: CGFloat = 60
    var corner: CGFloat = 9
    var showsStatus = false
    var accessibilityID = "serverArtwork"
    let load: @MainActor (Int) async throws -> Data?
    @StateObject private var state = ServerArtworkState()
    @State private var retry = 0

    private var request: ServerArtworkRequest {
        ServerArtworkRequest(key: key, scope: scope, pixels: min(max(pixels, 1), 700), retry: retry)
    }
    // Render guards clear stale artwork on the very first account/key change,
    // before SwiftUI starts the replacement task or invokes onChange.
    private var isCurrent: Bool { scope != nil && state.request == request }
    private var image: UIImage? { isCurrent ? state.image : nil }
    private var phase: ServerArtworkPhase { isCurrent ? state.phase : .idle }

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .frame(width: size, height: size)
                .overlay {
                    // The fixed square, not image dimensions, owns all geometry.
                    ZStack {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.38, weight: .regular))
                            .foregroundStyle(.secondary)
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: size, height: size).clipped()
                        }
                        if phase == .loading {
                            ProgressView().controlSize(.small).padding(6)
                                .background(.regularMaterial, in: Circle())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(5)
                        }
                    }
                    .frame(width: size, height: size).clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(symbol == "music.note.list" ? "歌单封面" : "专辑封面")
                .accessibilityValue(phase.message)
                .accessibilityIdentifier(accessibilityID)
            if showsStatus && phase != .loaded {
                Text(phase.message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(accessibilityID + ".status")
                if phase == .failed && scope != nil {
                    Button { retry += 1 } label: {
                        Label("重试封面", systemImage: "arrow.clockwise")
                            .font(.caption).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(accessibilityID + ".retry")
                }
            }
        }
        .frame(width: size)
        .task(id: request) {
            guard !Task.isCancelled else { return }
            state.start(request, load: load)
        }
        .onChange(of: request) { value in state.invalidate(unless: value) }
        .onDisappear { state.cancel() }
    }
}

@MainActor private final class ServerArtworkState: ObservableObject {
    @Published private(set) var request: ServerArtworkRequest?
    @Published private(set) var image: UIImage?
    @Published private(set) var phase: ServerArtworkPhase = .idle
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    func invalidate(unless next: ServerArtworkRequest) {
        if request != next { cancel() }
    }
    func cancel() {
        generation = UUID()
        worker?.cancel(); watchdog?.cancel()
        worker = nil; watchdog = nil
        image = nil; request = nil; phase = .idle
    }
    func start(_ next: ServerArtworkRequest, load: @escaping @MainActor (Int) async throws -> Data?) {
        cancel()
        request = next
        guard let scope = next.scope, !scope.isEmpty else { return }
        let ticket = generation
        phase = .loading
        worker = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let data = try await load(next.pixels)
                try Task.checkCancellation()
                guard let self, self.generation == ticket, self.request == next else { return }
                if let data {
                    if let image = Self.thumbnail(data, pixels: next.pixels) {
                        self.image = image; self.phase = .loaded
                    } else { self.phase = .failed }
                } else { self.phase = .missing }
            } catch is CancellationError {
                guard let self, self.generation == ticket, self.request == next else { return }
                self.phase = .idle
            } catch {
                guard let self, !Task.isCancelled, self.generation == ticket, self.request == next else { return }
                // No raw errors, URLs, or credentials are ever displayed here.
                self.phase = .failed
            }
            guard let self, self.generation == ticket, self.request == next else { return }
            self.watchdog?.cancel(); self.watchdog = nil; self.worker = nil
        }
        // A single bounded attempt, not a retry loop. Invalidate first so even
        // a non-cooperative late completion cannot replace the failed placeholder.
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == ticket, self.request == next else { return }
            self.generation = UUID()
            self.worker?.cancel(); self.worker = nil; self.watchdog = nil
            self.image = nil; self.phase = .failed
        }
    }
    private static func thumbnail(_ data: Data, pixels: Int) -> UIImage? {
        guard data.count <= 4_000_000,
              let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 80_000_000,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(pixels, 1), 700),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
