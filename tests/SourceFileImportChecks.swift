import Foundation
import UniformTypeIdentifiers

@main @MainActor struct SourceFileImportChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        func rejects(_ expected: SourceImportFailure, _ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure("expected \(expected)") }
            catch { check(error as? SourceImportFailure == expected, "rejected with \(expected), not raw filesystem error") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourceImportChecks-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = Data("/* @name Test source */\nthrow Error('must-not-run-during-import');\n".utf8)
        check(Set(SourceFileImport.pickerTypes) == Set([UTType.content, .data]), "select physical data files, never the generic folder-item type")
        for type in [UTType.javaScript, .plainText, .data] {
            check(SourceFileImport.pickerTypes.contains { type.conforms(to: $0) }, "JS and generic provider classifications selectable")
        }
        for filename in ["music.js", "MUSIC.JS", "中文 音源 v1.js"] {
            let url = root.appendingPathComponent(filename)
            try data.write(to: url)
            let file = try await SourceFileImport.read(url)
            check(file.data == data && file.filename == filename, "selected source preserves original bytes and name")
        }
        let accepted = root.appendingPathComponent("music.js")
        let file = try await SourceFileImport.read(accepted)
        let store = SourceStore(directory: root.appendingPathComponent("saved"))
        try store.importScript(file.data, filename: file.filename)
        check(store.sources.count == 1 && store.sources[0].name == "Test source", "real file to existing import pipeline")
        check(store.sources[0].state == .quarantined && !store.sources[0].isTrusted && !store.sources[0].isEnabled, "selection is not execution or trust")
        let reloaded = SourceStore(directory: root.appendingPathComponent("saved"))
        let persisted = try reloaded.scriptText(reloaded.sources[0].id)
        check(Data(persisted.utf8) == data && !reloaded.hasEnabledSources, "persisted still quarantined")
        do { try store.importScript(file.data, filename: file.filename); preconditionFailure("duplicate imported") }
        catch { check(error as? SourceFailure == .duplicate && store.sources.count == 1, "existing duplicate protection preserved") }
        for name in [".js.txt", "script.zip", "document.pdf", "no-extension"] {
            let url = root.appendingPathComponent(name); try data.write(to: url)
            await rejects(.fileType) { _ = try await SourceFileImport.read(url) }
        }
        let folder = root.appendingPathComponent("folder.js", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        await rejects(.notFile) { _ = try await SourceFileImport.read(folder) }
        let link = root.appendingPathComponent("linked.js")
        try fm.createSymbolicLink(at: link, withDestinationURL: accepted)
        await rejects(.notFile) { _ = try await SourceFileImport.read(link) }
        await rejects(.notFile) { _ = try await SourceFileImport.read(URL(string: "https://example.invalid/script.js")!) }
        await rejects(.unavailable) { _ = try await SourceFileImport.read(root.appendingPathComponent("missing.js")) }
        for (index, invalid) in [Data(), Data(" \n\t".utf8), Data([0xef,0xbb,0xbf]), Data([0xff,0xfe,0xff]), Data([0,65])].enumerated() {
            let url = root.appendingPathComponent("invalid\(index).js"); try invalid.write(to: url)
            await rejects(.invalidText) { _ = try await SourceFileImport.read(url) }
        }
        let maximum = root.appendingPathComponent("maximum.js")
        try Data(repeating: 0x20, count: SourceFileImport.maximumBytes - 1).appendingByte(0x31).write(to: maximum)
        let maximumFile = try await SourceFileImport.read(maximum)
        check(maximumFile.data.count == SourceFileImport.maximumBytes, "one MiB accepted exactly")
        let oversized = root.appendingPathComponent("oversized.js")
        try Data(repeating: 0x31, count: SourceFileImport.maximumBytes + 1).write(to: oversized)
        await rejects(.tooLarge) { _ = try await SourceFileImport.read(oversized) }
        check(SourceImportFailure.isCancellation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)), "picker cancel is not failure alert")
        check(!SourceImportFailure.isCancellation(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), "real read failure not hidden")
        check(!SourceImportFailure.unavailable.localizedDescription.contains(root.path), "filesystem path never shown")
        let pasted = try SourceFileImport.pasted("/* @name Pasted */\nthrow Error('never execute');", filename: "手动.JS")
        try store.importScript(pasted.data, filename: pasted.filename)
        check(store.sources.count == 2 && !store.sources[1].isTrusted && !store.sources[1].isEnabled && store.sources[1].state == .quarantined, "explicit paste uses quarantine only")
        await rejects(.tooLarge) { _ = try SourceFileImport.pasted(String(repeating: "中", count: SourceFileImport.maximumBytes / 3 + 1), filename: "paste.js") }
        await rejects(.fileType) { _ = try SourceFileImport.pasted("1", filename: "paste.txt") }
        await rejects(.fileType) { _ = try SourceFileImport.pasted("1", filename: "../paste.js") }
        await rejects(.invalidText) { _ = try SourceFileImport.pasted("\u{FEFF}\n ", filename: "paste.js") }
        // A blocked coordinator/provider must not hold the logical read hostage.
        let stalled = DispatchSemaphore(value: 0)
        let began = Date()
        await rejects(.timedOut) {
            _ = try await SourceFileImport.performRead(timeout: 0.04) { _ in
                _ = stalled.wait(timeout: .now() + 2)
                return SourceImportFile(data: data, filename: "late.js")
            }
        }
        check(Date().timeIntervalSince(began) < 1, "deadline returns independently of stalled provider")
        stalled.signal()
        let cancelled = DispatchSemaphore(value: 0)
        let task = Task {
            try await SourceFileImport.performRead(timeout: 2) { _ in
                _ = cancelled.wait(timeout: .now() + 2)
                return SourceImportFile(data: data, filename: "late-cancel.js")
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelBegan = Date(); task.cancel()
        do { _ = try await task.value; preconditionFailure("cancelled read returned success") }
        catch { check(SourceImportFailure.isCancellation(error), "cancel resumes immediately") }
        check(Date().timeIntervalSince(cancelBegan) < 1, "cancel does not wait for provider")
        cancelled.signal()
        var ticketPolicy = SourcePickerPolicy()
        let old = ticketPolicy.begin()
        check(ticketPolicy.selected(old), "first delegate callback starts read")
        check(!ticketPolicy.selected(old), "duplicate delegate cannot start second read")
        ticketPolicy.cancel()
        check(!ticketPolicy.finish(old), "late cancelled result cannot import")
        let current = ticketPolicy.begin()
        check(!ticketPolicy.selected(old) && ticketPolicy.selected(current), "superseded selection rejected")
        check(ticketPolicy.finish(current) && !ticketPolicy.finish(current), "completion permits one import only")
        print("PASS: \(count) native picker policy, deadline/cancel, bounded copy, paste and quarantine checks; no script execution")
    }
}
private extension Data {
    func appendingByte(_ byte: UInt8) -> Data { var result = self; result.append(byte); return result }
}
