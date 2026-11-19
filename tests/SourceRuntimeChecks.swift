// macOS offline integration checks. Synthetic scripts only; example.invalid is never fetched.
import Foundation

@main @MainActor struct SourceRuntimeChecks {
    static let declaration = "lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac']},kg:{type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac']}}});"
    static var bootstrap: URL {
        URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/TingFlow/Sources/SourceBootstrap.js")
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func source(_ script: String) -> UserSource {
        var value = UserSource(id: UUID(), sha256: SourceURLPolicy.sha256(Data(script.utf8)), name: "synthetic", version: "1", author: "test", description: "")
        value.isTrusted = true; value.isEnabled = true; value.allowedHosts = ["example.invalid"]
        return value
    }
    static func engine(_ script: String, seconds: Double = 0.5) -> SourceRuntime {
        SourceRuntime(source: source(script), script: script, bootstrapURL: bootstrap,
                      initializationTimeout: seconds, requestTimeout: seconds)
    }
    static func fails(_ expected: SourceFailure, _ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure("expected \(expected)") }
        catch { check((error as? SourceFailure) == expected, "expected \(expected), got \(error)") }
    }
    static func main() async throws {
        let kg = Song(platform: .kugou, platformID: "12345", title: "Song", artist: "Artist", album: "Album", duration: 99,
                      hash: "h128", highQualityHash: "h320", losslessHash: "hflac", accountScope: "must-not-enter-JS")
        let wy = Song(platform: .netease, platformID: "9007199254740993", title: "Song", artist: "Artist", album: "Album", duration: 99)
        let success = """
        lx.on('request', async r => {
          const m = r.info.musicInfo;
          if (typeof r !== 'object' || r.action !== 'musicUrl' || r.info.type !== '320k' || m.interval !== '01:39' || m.accountScope !== undefined) throw Error('mapping');
          if (r.source === 'kg' && (m.songmid !== '12345' || m.hash !== 'h128' || m._types['320k'].hash !== 'h320' || m.albumAudioId !== '12345')) throw Error('kg');
          if (r.source === 'wy' && (m.songmid !== '9007199254740993' || m.hash !== undefined)) throw Error('wy');
          return 'https://example.invalid/audio';
        });
        """ + declaration
        let good = engine(success); defer { good.retire() }
        try await good.initialize()
        check(good.capabilities["kg"] != nil, "capabilities after evaluation")
        for song in [kg, wy] {
            let resource = try await good.resolve(song: song, quality: .high)
            check(resource.url.absoluteString == "https://example.invalid/audio", "real JS return reaches PlaybackResource")
            check(resource.headers.isEmpty && resource.displayQuality.contains("请求音质：320k") && resource.displayQuality.contains("未验证"), "no claimed quality verification")
        }
        let unsupported = Song(platform: .emby, platformID: "1", title: "", artist: "", album: "", duration: 0)
        await fails(.unsupported) { _ = try await good.resolve(song: unsupported, quality: .standard) }
        let rejected = engine("lx.on('request', () => Promise.reject(Error('fixture')));" + declaration)
        defer { rejected.retire() }; try await rejected.initialize()
        await fails(.script) { _ = try await rejected.resolve(song: wy, quality: .standard) }
        let throwsAfterInit = engine("lx.on('request', async () => 'https://example.invalid/a');" + declaration + "throw Error('after inited');")
        defer { throwsAfterInit.retire() }
        await fails(.script) { try await throwsAfterInit.initialize() }
        check(throwsAfterInit.capabilities.isEmpty, "inited followed by throw must not be ready")
        let missing = engine("lx.on('request', async () => 'https://example.invalid/a');", seconds: 0.05)
        defer { missing.retire() }
        await fails(.timeout) { try await missing.initialize() }
        let pending = engine("lx.on('request', () => new Promise(() => {}));" + declaration, seconds: 0.05)
        defer { pending.retire() }; try await pending.initialize()
        let start = Date()
        await fails(.timeout) { _ = try await pending.resolve(song: wy, quality: .standard) }
        check(Date().timeIntervalSince(start) < 2, "deadline is not a task-group join")
        let cancel = engine("lx.on('request', () => new Promise(resolve => setTimeout(() => resolve('https://example.invalid/late'), 400)));" + declaration)
        defer { cancel.retire() }; try await cancel.initialize()
        let task = Task { try await cancel.resolve(song: wy, quality: .standard) }
        try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
        await fails(.cancelled) { _ = try await task.value }
        try await utilityChecks(wy)
        try await storeChecks(wy)
        // Last: this deliberately leaves one worker spinning until this test process exits.
        let loopScript = "while(true) {} // synthetic hard-loop"
        let loop = engine(loopScript, seconds: 0.05)
        await fails(.timeout) { try await loop.initialize() }
        check(SourceRuntime.isQuarantined(source(loopScript).sha256), "busy JS hash blocked until process restart")
        let rerun = engine(loopScript); defer { rerun.retire() }
        await fails(.retired) { try await rerun.initialize() }
        print("PASS: synthetic JSC lifecycle, legacy parameters, utilities, deadlines/cancel, trust/persistence/order/fallback")
    }

    static func utilityChecks(_ song: Song) async throws {
        let script = """
        const b = lx.utils.buffer, c = lx.utils.crypto;
        const assert = ok => { if (!ok) throw Error('utility vector'); };
        assert(b.bufToString(b.from('你好'), 'base64') === '5L2g5aW9');
        assert(b.bufToString(b.from('5L2g5aW9', 'base64')) === '你好');
        assert(b.bufToString(b.from('00ff', 'hex'), 'hex') === '00ff');
        assert(c.md5('abc') === '900150983cd24fb0d6963f7d28e17f72');
        assert(c.randomBytes(0).length === 0 && c.randomBytes(16).length === 16);
        const hex = s => b.from(s, 'hex');
        assert(b.bufToString(c.aesEncrypt(hex('00112233445566778899aabbccddeeff'), 'aes-128-ecb', hex('000102030405060708090a0b0c0d0e0f'), []), 'hex') === '69c4e0d86a7b0430d8cdb78070b4c55a');
        const cbc = c.aesEncrypt(hex('6bc1bee22e409f96e93d7e117393172a'), 'aes-128-cbc', hex('2b7e151628aed2a6abf7158809cf4f3c'), hex('000102030405060708090a0b0c0d0e0f'));
        assert(cbc.length === 32 && b.bufToString(cbc, 'hex').startsWith('7649abac8119b246cee98e9b12e9197d'));
        let rsaUnsupported = false; try { c.rsaEncrypt([], 'key'); } catch(e) { rsaUnsupported = /unsupported/i.test(e.message); } assert(rsaUnsupported);
        lx.on('request', () => new Promise(resolve => {
          lx.request('http://example.invalid/blocked', {}, (err, resp, body) => {
            assert(!!err && resp === null && body === null);
            setTimeout(() => resolve('https://example.invalid/utilities'), 1);
          });
        }));
        """ + declaration
        let runtime = engine(script); defer { runtime.retire() }
        try await runtime.initialize()
        let resource = try await runtime.resolve(song: song, quality: .standard)
        check(resource.url.path == "/utilities", "native utility vectors and blocked HTTP callback")
    }
    static func storeChecks(_ song: Song) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourceRuntimeChecks-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let store = SourceStore(directory: root, bootstrapURL: bootstrap, initializationTimeout: 0.5, requestTimeout: 0.5)
        let bad = "/**\n * @name Reject fixture\n * @author Offline test\n * @version 1.2\n */\nlx.on('request', () => Promise.reject(Error('fallback')));" + declaration
        let good = "/*\n@name Good fixture\n@description No actual audio tested\n*/\nlx.on('request', async () => 'https://example.invalid/store');" + declaration
        try store.importScript(Data(bad.utf8), filename: "bad.js")
        try store.importScript(Data(good.utf8), filename: "good.js")
        check(store.sources[0].name == "Reject fixture" && store.sources[0].author == "Offline test", "LX initial block metadata")
        check(!store.hasEnabledSources && store.sources.allSatisfy { !$0.isTrusted && !$0.isEnabled }, "import quarantines without evaluating")
        await fails(.duplicate) { try store.importScript(Data(good.utf8), filename: "duplicate.js") }
        let badID = store.sources[0].id, goodID = store.sources[1].id
        let reviewed = try store.scriptText(goodID)
        check(reviewed == good, "raw source review")
        try store.trust(badID, hosts: "example.invalid")
        try store.trust(goodID, hosts: "example.invalid")
        store.setEnabled(goodID, false); check(!store.sources[1].isEnabled, "disable")
        store.setEnabled(goodID, true)
        store.move(goodID, offset: -1); check(store.sources.first?.id == goodID, "published order moves")
        store.setOrder([badID, badID]); check(store.sources.map(\.id) == [badID, goodID], "partial order preserves all sources once")
        let reload = SourceStore(directory: root, bootstrapURL: bootstrap, initializationTimeout: 0.5, requestTimeout: 0.5)
        check(reload.sources.map(\.id) == [badID, goodID] && reload.sources.allSatisfy { $0.capabilities.isEmpty && $0.state == .idle }, "durable trust/order, ephemeral readiness")
        check(reload.supports(.netease) && !reload.supports(.emby), "platform gate")
        let resource = try await reload.playback(for: song, quality: .standard)
        check(resource.url.path == "/store" && reload.sources[0].state == .failed && reload.sources[1].state == .ready && !reload.isBusy, "ordered runtime fallback")
        let metadata = root.appendingPathComponent("sources.json"), snapshot = reload.sources
        let bytes = try Data(contentsOf: metadata)
        try fm.removeItem(at: metadata); try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        reload.setEnabled(goodID, false)
        check(reload.sources == snapshot && reload.errorMessage != nil, "failed atomic persist rolls published state back")
        try fm.removeItem(at: metadata); try bytes.write(to: metadata)
        let pending = "/* @name Cancellation fixture */\nlx.on('request', () => new Promise(() => {}));" + declaration
        try reload.importScript(Data(pending.utf8), filename: "pending.js")
        let pendingID = reload.sources.last!.id
        try reload.trust(pendingID, hosts: "example.invalid")
        reload.setOrder([pendingID, goodID, badID]); reload.setEnabled(goodID, true)
        let task = Task { try await reload.playback(for: song, quality: .standard) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        await fails(.cancelled) { _ = try await task.value }
        check(reload.sources.first(where: { $0.id == goodID })?.state == .idle && !reload.isBusy, "cancel never attempts next source")
    }
}
