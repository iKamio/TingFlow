import Foundation
import UniformTypeIdentifiers

struct SourceImportFile {
    let data: Data
    let filename: String
}

enum SourceImportFailure: LocalizedError, Equatable {
    case fileType, notFile, tooLarge, invalidText, unavailable, timedOut
    var errorDescription: String? {
        switch self {
        case .fileType: return "请选择 .js 音源文件。如果下载后文件名变成 .js.txt，请在“文件”App 中确认并改回 .js；压缩包需先解压。"
        case .notFile: return "请选择一个普通 .js 文件，不能导入文件夹、链接或文件包。"
        case .tooLarge: return "音源超过 1 MiB，未导入。请选择原始 JavaScript 音源文件。"
        case .invalidText: return "文件不是有效的 UTF-8 JavaScript 文本或内容为空，未导入。"
        case .unavailable: return "暂时无法读取所选文件。请在“文件”App 中确认已下载完成、可正常打开，再重新选择；也可手动粘贴 JavaScript 文本。"
        case .timedOut: return "读取文件超时，已停止本次导入。请先在“文件”App 下载到本机后重试，或手动粘贴 JavaScript 文本。"
        }
    }
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError) ||
            (value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled)
    }
}

/// Main-actor UI ticket. Delegate duplicates, replaced requests and late reads cannot commit.
struct SourcePickerPolicy {
    enum Phase { case idle, selecting, reading }
    private(set) var id = UUID()
    private(set) var phase: Phase = .idle
    mutating func begin() -> UUID { id = UUID(); phase = .selecting; return id }
    mutating func selected(_ ticket: UUID) -> Bool {
        guard ticket == id, phase == .selecting else { return false }
        phase = .reading; return true
    }
    mutating func finish(_ ticket: UUID) -> Bool {
        guard ticket == id, phase == .reading else { return false }
        phase = .idle; return true
    }
    mutating func cancel() { id = UUID(); phase = .idle }
}

/// A single-shot continuation, NOT a task group: leaving a task group waits for a
/// stuck provider. Cancellation/deadline here return without waiting for coordination.
private final class SourceImportReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: Result<SourceImportFile, Error>?
    private var continuation: CheckedContinuation<SourceImportFile, Error>?
    private var timer: DispatchSourceTimer?
    func install(_ value: CheckedContinuation<SourceImportFile, Error>) -> Bool {
        lock.lock()
        if let terminal { lock.unlock(); value.resume(with: terminal); return false }
        continuation = value; lock.unlock(); return true
    }
    func arm(_ seconds: TimeInterval) {
        let value = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        value.schedule(deadline: .now() + max(0.001, seconds))
        value.setEventHandler { [weak self] in self?.resolve(.failure(SourceImportFailure.timedOut)) }
        value.resume()
        lock.lock()
        if terminal != nil { lock.unlock(); value.cancel(); return }
        timer = value; lock.unlock()
    }
    func checkActive() throws {
        lock.lock(); let stopped = terminal != nil; lock.unlock()
        if stopped { throw CancellationError() }
    }
    func resolve(_ result: Result<SourceImportFile, Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let callback = continuation; continuation = nil
        let deadline = timer; timer = nil
        lock.unlock()
        deadline?.cancel(); callback?.resume(with: result)
    }
}

/// Broad selection is intentional; application validation never evaluates JavaScript.
enum SourceFileImport {
    static let maximumBytes = 1024 * 1024
    static let readTimeout: TimeInterval = 15
    /// Select files, not UTType.item (which also admits provider folder packages).
    /// Some Files providers label downloaded .js as plain text or generic data.
    static var pickerTypes: [UTType] { [.content, .data] }
    // Bound the number of physical reads even if a provider never releases coordination.
    private static let readers: OperationQueue = {
        let queue = OperationQueue(); queue.name = "TingFlow.SourceImport"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
        return queue
    }()
    static func validate(_ data: Data, filename: String) throws {
        try validateFilename(filename)
        guard data.count <= maximumBytes else { throw SourceImportFailure.tooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty
        else { throw SourceImportFailure.invalidText }
    }
    static func validateFilename(_ name: String) throws {
        guard !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              URL(fileURLWithPath: name).pathExtension.lowercased() == "js"
        else { throw SourceImportFailure.fileType }
    }
    static func pasted(_ text: String, filename: String) throws -> SourceImportFile {
        // Count UTF-8 bytes, not characters, before allocating another copy.
        guard text.utf8.count <= maximumBytes else { throw SourceImportFailure.tooLarge }
        let data = Data(text.utf8); try validate(data, filename: filename)
        return SourceImportFile(data: data, filename: filename)
    }
    static func read(_ url: URL, timeout: TimeInterval = readTimeout) async throws -> SourceImportFile {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SourceImportFailure.notFile }
        try validateFilename(url.lastPathComponent)
        return try await performRead(timeout: timeout) { check in try readCopied(url, check: check) }
    }
    /// Internal deterministic test seam; no network, document picker or JS engine needed.
    static func performRead(timeout: TimeInterval, work: @escaping (@escaping () throws -> Void) throws -> SourceImportFile) async throws -> SourceImportFile {
        let gate = SourceImportReadGate()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                gate.arm(timeout)
                readers.addOperation {
                    do {
                        try gate.checkActive()
                        let value = try work { try gate.checkActive() }
                        try gate.checkActive()
                        gate.resolve(.success(value))
                    } catch {
                        let safe: Error = SourceImportFailure.isCancellation(error) ? CancellationError() :
                            ((error as? SourceImportFailure) ?? .unavailable)
                        gate.resolve(.failure(safe))
                    }
                }
            }
        }, onCancel: { gate.resolve(.failure(CancellationError())) })
    }
    private static func readCopied(_ url: URL, check: () throws -> Void) throws -> SourceImportFile {
        try check()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw SourceImportFailure.notFile }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatedError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatedError) { readable in
            result = Result {
                try check()
                // asCopy gives us the provider's copy. Make our own bounded staging copy
                // while access is valid; never retain a provider URL in SourceStore.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("SourceImport-\(UUID()).js")
                defer { try? FileManager.default.removeItem(at: copy) }
                let bytes = try readBounded(readable, check: check)
                try check(); try bytes.write(to: copy, options: .atomic)
                return try readBounded(copy, check: check)
            }
        }
        try check()
        if let coordinatedError {
            if SourceImportFailure.isCancellation(coordinatedError) { throw CancellationError() }
            throw SourceImportFailure.unavailable
        }
        guard let result else { throw SourceImportFailure.unavailable }
        let data = try result.get()
        try validate(data, filename: url.lastPathComponent)
        return SourceImportFile(data: data, filename: url.lastPathComponent)
    }
    private static func readBounded(_ url: URL, check: () throws -> Void) throws -> Data {
        try check()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isDirectory != true, values.isSymbolicLink != true, values.isPackage != true else { throw SourceImportFailure.notFile }
        if let size = values.fileSize, size > maximumBytes { throw SourceImportFailure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try check()
            guard let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumBytes else { throw SourceImportFailure.tooLarge }
        }
        try check(); return data
    }
}
