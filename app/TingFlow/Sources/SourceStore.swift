import Foundation
import Combine

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var sources: [UserSource] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var attempts: [SourceAttempt] = []
    @Published var selection: SourceSelection = .automatic {
        didSet {
            guard selection != oldValue else { return }
            revision = UUID(); attempts = []
            selectionDefaults?.set(selection.storedValue, forKey: "sourceSelection.v1")
        }
    }
    private var revision = UUID()
    private let selectionDefaults: UserDefaults?
    private let root: URL
    private let metadataURL: URL
    private let bootstrapURL: URL?
    private let initializationTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let fileManager = FileManager.default

    init(directory: URL? = nil, bootstrapURL: URL? = nil,
         initializationTimeout: TimeInterval = 10, requestTimeout: TimeInterval = 20) {
        selectionDefaults = directory == nil ? .standard : nil
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TingFlow/Sources", isDirectory: true)
        selection = SourceSelection(stored: selectionDefaults?.string(forKey: "sourceSelection.v1"))
        metadataURL = root.appendingPathComponent("sources.json")
        self.bootstrapURL = bootstrapURL
        self.initializationTimeout = initializationTimeout; self.requestTimeout = requestTimeout
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            #if os(iOS)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            #endif
            if fileManager.fileExists(atPath: metadataURL.path) {
                let saved = try JSONDecoder().decode([UserSource].self, from: Data(contentsOf: metadataURL))
                guard Set(saved.map(\.id)).count == saved.count, Set(saved.map(\.sha256)).count == saved.count else { throw SourceFailure.storage }
                sources = saved.map(Self.durable)
            }
        } catch { errorMessage = SourceFailure.storage.localizedDescription }
        selection = SourceSelection(stored: selectionDefaults?.string(forKey: "sourceSelection.v1"))
    }
    private static func durable(_ original: UserSource) -> UserSource {
        var value = original
        value.capabilities = [:]; value.isEnabled = value.isEnabled && value.isTrusted && !value.allowedHosts.isEmpty
        value.state = value.isTrusted ? .idle : .quarantined
        return value
    }
    var configurationID: UUID { revision }
    var hasEnabledSources: Bool { !selectedSources.isEmpty }
    var selectedSources: [UserSource] {
        SourceSelectionPolicy.candidates(sources, selection: selection).filter { !SourceRuntime.isQuarantined($0.sha256) }
    }
    var selectionLabel: String {
        switch selection {
        case .automatic: return "自动 · 按启用顺序"
        case .source(let id): return sources.first { $0.id == id }?.name ?? "所选音源已不可用"
        }
    }
    func supports(_ platform: MusicPlatform) -> Bool {
        guard platform == .netease || platform == .kugou else { return false }
        return selectedSources.contains {
            $0.capabilities.isEmpty || $0.capabilities[platform.rawValue]?.actions.contains("musicUrl") == true
        }
    }
    private func scriptURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).js") }
    /// Review does not create an engine or execute any JavaScript.
    func scriptText(_ id: UUID) throws -> String {
        guard let source = sources.first(where: { $0.id == id }) else { throw SourceFailure.storage }
        let data = try Data(contentsOf: scriptURL(id))
        guard data.count <= 1024 * 1024, SourceURLPolicy.sha256(data) == source.sha256,
              let raw = String(data: data, encoding: .utf8) else { throw SourceFailure.invalidScript }
        return raw
    }
    private func save(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        // The parent directory is excluded from backup, including all atomically replaced files.
    }
    /// Publish only after the atomic metadata replacement succeeds; callers keep the old snapshot on error.
    private func commit(_ next: [UserSource]) throws {
        do { try save(JSONEncoder().encode(next.map(Self.durable)), to: metadataURL) }
        catch { errorMessage = SourceFailure.storage.localizedDescription; throw SourceFailure.storage }
        revision = UUID(); attempts = []
        sources = next; errorMessage = nil
    }
    func importScript(_ data: Data, filename: String) throws {
        guard data.count <= 1024 * 1024, let raw = String(data: data, encoding: .utf8) else { throw SourceFailure.invalidScript }
        let hash = SourceURLPolicy.sha256(data)
        guard !sources.contains(where: { $0.sha256 == hash }) else { throw SourceFailure.duplicate }
        let prefix = String(raw.prefix(16384))
        func capture(_ pattern: String, in text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let block = capture(#"\A[\s\uFEFF]*/\*([\s\S]*?)\*/"#, in: prefix)
        func meta(_ key: String, _ fallback: String, _ limit: Int) -> String {
            let value = block.flatMap { capture("(?m)^\\s*\\*?\\s*@\(key)[ \\t]+([^\\r\\n]*)", in: $0) }
                ?? capture("(?m)^\\s*//\\s*@\(key)[ \\t]+([^\\r\\n]*)", in: prefix) ?? fallback
            return String(value.prefix(limit))
        }
        let name = meta("name", URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent, 24)
        let source = UserSource(id: UUID(), sha256: hash, name: name.isEmpty ? "我的音源" : name,
                                version: meta("version", "未声明", 36), author: meta("author", "未知", 56), description: meta("description", "", 36))
        let url = scriptURL(source.id)
        do { try save(data, to: url); try commit(sources + [source]) }
        catch { try? fileManager.removeItem(at: url); throw SourceFailure.storage }
    }

    func trust(_ id: UUID, hosts raw: String) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw SourceFailure.storage }
        let hosts = try SourceURLPolicy.hosts(raw)
        guard !hosts.isEmpty else { throw SourceFailure.permission }
        _ = try scriptText(id)
        var next = sources
        next[index].allowedHosts = hosts; next[index].isTrusted = true; next[index].isEnabled = true
        next[index].state = .idle; next[index].capabilities = [:]
        try commit(next)
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var next = sources
        next[index].isEnabled = enabled && next[index].isTrusted && !next[index].allowedHosts.isEmpty
        next[index].state = next[index].isTrusted ? .idle : .quarantined; next[index].capabilities = [:]
        do { try commit(next) } catch { }
    }
    func setOrder(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let ordered = ids.compactMap { id -> UserSource? in
            guard seen.insert(id).inserted else { return nil }; return sources.first { $0.id == id }
        }
        let next = ordered + sources.filter { !seen.contains($0.id) }
        do { try commit(next) } catch { }
    }
    func move(_ id: UUID, offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), sources.count - 1)
        guard target != index else { return }
        var next = sources; next.swapAt(index, target)
        do { try commit(next) } catch { }
    }
    func delete(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        do {
            try commit(sources.filter { $0.id != id })
            try fileManager.removeItem(at: scriptURL(id))
        } catch { errorMessage = SourceFailure.storage.localizedDescription }
    }
    private func state(_ id: UUID, _ state: UserSource.State, caps: [String: SourceCapability] = [:]) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].state = state; sources[index].capabilities = caps
    }
    func playback(for song: Song, quality: AudioQuality = .standard, preservingAttempts: Bool = false) async throws -> PlaybackResource {
        try Task.checkCancellation()
        guard !isBusy else { throw SourceFailure.busy }
        isBusy = true; errorMessage = nil
        if !preservingAttempts { attempts = [] }
        let token = revision
        defer { isBusy = false }
        let candidates = SourceSelectionPolicy.candidates(sources, selection: selection)
        for original in candidates {
            try Task.checkCancellation()
            guard revision == token else { throw CancellationError() }
            let id = original.id
            guard !SourceRuntime.isQuarantined(original.sha256) else {
                state(id, .failed)
                attempts.append(SourceAttempt(sourceID: id, name: original.name, platform: song.platform, outcome: .failed(.retired)))
                continue
            }
            do {
                let script = try scriptText(id)
                try Task.checkCancellation()
                let engine = SourceRuntime(source: original, script: script, bootstrapURL: bootstrapURL,
                                           initializationTimeout: initializationTimeout, requestTimeout: requestTimeout)
                defer { engine.retire() }
                state(id, .initializing)
                try await engine.initialize()
                try Task.checkCancellation()
                let caps = engine.capabilities
                guard revision == token, let current = sources.first(where: { $0.id == id }), current.isEnabled, current.isTrusted,
                      current.allowedHosts == original.allowedHosts else { throw CancellationError() }
                guard let capability = caps[song.platform.rawValue], capability.actions.contains("musicUrl"),
                      let supportedQuality = capability.compatibleQuality(quality) else { throw SourceFailure.unsupported }
                state(id, .ready, caps: caps)
                var resource = try await engine.resolve(song: song, quality: supportedQuality)
                resource.sourceLabel = "自定义音源 · " + original.name
                try Task.checkCancellation()
                guard revision == token, sources.contains(where: { $0.id == id && $0.isEnabled && $0.isTrusted && $0.allowedHosts == original.allowedHosts }) else { throw CancellationError() }
                attempts.append(SourceAttempt(sourceID: id, name: original.name, platform: song.platform, outcome: .success))
                return resource
            } catch {
                guard revision == token else { throw CancellationError() }
                state(id, .failed)
                let reason = SourceSelectionPolicy.failure(error)
                attempts.append(SourceAttempt(sourceID: id, name: original.name, platform: song.platform, outcome: .failed(reason)))
                if error is CancellationError || reason == .cancelled || Task.isCancelled {
                    errorMessage = SourceFailure.cancelled.localizedDescription
                    throw SourceFailure.cancelled
                }
            }
        }
        let error: MusicError
        if candidates.isEmpty {
            error = .unsupported(selection == .automatic ? MusicError.noSource.localizedDescription : "所选音源已停用、删除或尚未授权。请重新选择，不会自动改用其他音源。")
        } else {
            error = .unsupported("所选音源未返回可用地址。可在播放页或音源设置查看每个源的失败原因；导入成功不等于支持此歌曲。")
        }
        errorMessage = error.localizedDescription
        throw error
    }
}
