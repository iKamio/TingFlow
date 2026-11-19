import Foundation
import JavaScriptCore
import CryptoKit
import Security
import CommonCrypto

/// Independent of the JS queue: even a non-cooperative script cannot hold its caller's continuation.
private final class SourceDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: DispatchWorkItem?
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    @discardableResult func finish(_ value: Result<Value, Error>, beforeResume: () -> Void = {}) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let c = continuation; continuation = nil
        let t = timer; timer = nil
        lock.unlock(); t?.cancel(); beforeResume(); c?.resume(with: value); return true
    }
    func arm(seconds: TimeInterval, timeout: @escaping () -> Void) {
        let item = DispatchWorkItem(block: timeout)
        lock.lock(); if result == nil { timer = item } else { item.cancel() }; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.01, seconds), execute: item)
    }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let result { lock.unlock(); c.resume(with: result) }
            else { continuation = c; lock.unlock() }
        }
    }
}

/// Public JSC only; not a CPU/memory sandbox. One ephemeral runtime per playback attempt.
final class SourceRuntime: @unchecked Sendable {
    private static let quarantineLock = NSLock()
    private static var blockedHashes = Set<String>()
    static func isQuarantined(_ hash: String) -> Bool {
        quarantineLock.lock(); defer { quarantineLock.unlock() }; return blockedHashes.contains(hash)
    }
    private let queue = DispatchQueue(label: "TingFlow.SourceRuntime")
    private let lock = NSLock()
    private let info: UserSource
    private let script: String
    private let bootstrapURL: URL?
    private let initializationTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let http = SourceHTTP()
    private var retired = false
    private var executionDepth = 0
    private var activeID: UUID?
    private var activeFailure: ((Error) -> Void)?
    private var caps: [String: SourceCapability] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    // JS-queue confined below; never capture a JSContext/JSValue in its own exported blocks.
    private var context: JSContext?
    private var evaluated = false, registered = false
    private var candidate: [String: SourceCapability]?
    private var initGate: SourceDeadline<Void>?
    private var resultGate: SourceDeadline<PlaybackResource>?
    private var resultTicket = "", requestedQuality = ""
    private var requests: [String: String] = [:]
    var capabilities: [String: SourceCapability] { lock.lock(); defer { lock.unlock() }; return caps }

    init(source: UserSource, script: String, bootstrapURL: URL? = nil,
         initializationTimeout: TimeInterval = 10, requestTimeout: TimeInterval = 20) {
        info = source; self.script = script
        self.bootstrapURL = bootstrapURL ?? Bundle.main.url(forResource: "SourceBootstrap", withExtension: "js")
        self.initializationTimeout = initializationTimeout; self.requestTimeout = requestTimeout
    }
    private var live: Bool { lock.lock(); defer { lock.unlock() }; return !retired }
    private func beginOperation(_ id: UUID, failure: @escaping (Error) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !retired, !Self.isQuarantined(info.sha256) else { throw SourceFailure.retired }
        guard activeID == nil else { throw SourceFailure.busy }
        activeID = id; activeFailure = failure
    }
    private func endOperation(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if activeID == id { activeID = nil; activeFailure = nil }
    }
    private func operation<T>(seconds: TimeInterval, body: @escaping (SourceDeadline<T>) -> Void) async throws -> T {
        try Task.checkCancellation()
        let gate = SourceDeadline<T>(), id = UUID()
        try beginOperation(id, failure: { _ = gate.finish(.failure($0)) })
        defer { endOperation(id) }
        return try await withTaskCancellationHandler(operation: {
            gate.arm(seconds: seconds) { [weak self, weak gate] in
                _ = gate?.finish(.failure(SourceFailure.timeout), beforeResume: { self?.retire(reason: SourceFailure.timeout) })
            }
            queue.async { [self] in
                guard live, gate.isPending else { return }
                lock.lock(); executionDepth += 1; lock.unlock()
                defer { lock.lock(); executionDepth -= 1; lock.unlock() }
                body(gate)
            }
            return try await gate.wait()
        }, onCancel: { self.retire(reason: SourceFailure.cancelled) })
    }
    func retire() { retire(reason: SourceFailure.retired) }
    private func retire(reason: Error) {
        lock.lock()
        if retired { lock.unlock(); return }
        retired = true; caps = [:]
        let stuck = executionDepth > 0, failure = activeFailure
        let work = Array(timers.values); timers.removeAll()
        lock.unlock()
        if stuck && ((reason as? SourceFailure) == .timeout || (reason as? SourceFailure) == .cancelled) {
            Self.quarantineLock.lock(); Self.blockedHashes.insert(info.sha256); Self.quarantineLock.unlock()
        }
        failure?(reason) // settle before any queue cleanup or URLSession work
        work.forEach { $0.cancel() }; http.close()
        queue.async { [self] in
            context = nil; initGate = nil; resultGate = nil; requests.removeAll()
        }
    }

    func initialize() async throws {
        try await operation(seconds: initializationTimeout) { [self] (gate: SourceDeadline<Void>) in
            guard info.isTrusted, !info.allowedHosts.isEmpty else { gate.finish(.failure(SourceFailure.permission)); return }
            initGate = gate
            guard let bootstrapURL, let bootstrap = try? String(contentsOf: bootstrapURL, encoding: .utf8),
                  let ctx = JSContext() else { gate.finish(.failure(SourceFailure.storage)); return }
            context = ctx
            ctx.exceptionHandler = { [weak self] _, _ in self?.retire(reason: SourceFailure.script) }
            ctx.setObject(["name": info.name, "description": info.description, "version": info.version,
                           "author": info.author, "homepage": "", "rawScript": script], forKeyedSubscript: "__tfInfo" as NSString)
            ctx.setObject({ [weak self] (event: String, payload: String) -> Bool in
                self?.send(event, payload: payload) ?? false
            } as @convention(block) (String, String) -> Bool, forKeyedSubscript: "__tfSend" as NSString)
            ctx.setObject({ [weak self] (id: String, url: String, options: String) in
                self?.request(id: id, url: url, options: options)
            } as @convention(block) (String, String, String) -> Void, forKeyedSubscript: "__tfHTTP" as NSString)
            ctx.setObject({ [weak self] (id: String) in
                guard let self, let native = self.requests.removeValue(forKey: id) else { return }
                self.http.cancel(native)
            } as @convention(block) (String) -> Void, forKeyedSubscript: "__tfCancel" as NSString)
            ctx.setObject({ [weak self] (id: String, ms: Double) in self?.schedule(id, ms: ms)
            } as @convention(block) (String, Double) -> Void, forKeyedSubscript: "__tfTimer" as NSString)
            ctx.setObject({ [weak self] (id: String) in self?.clearTimer(id)
            } as @convention(block) (String) -> Void, forKeyedSubscript: "__tfClearTimer" as NSString)
            ctx.setObject({ [weak self] (ticket: String, ok: Bool, value: String) in self?.finish(ticket, ok: ok, value: value)
            } as @convention(block) (String, Bool, String) -> Void, forKeyedSubscript: "__tfFinish" as NSString)
            ctx.setObject({ (op: String, args: String) -> String in Self.crypto(op, args: args)
            } as @convention(block) (String, String) -> String, forKeyedSubscript: "__tfCrypto" as NSString)
            ctx.evaluateScript(bootstrap)
            guard live, ctx.exception == nil else { gate.finish(.failure(SourceFailure.script)); return }
            ctx.evaluateScript(script)
            guard live, ctx.exception == nil else { gate.finish(.failure(SourceFailure.script)); return }
            evaluated = true; completeInitialization()
        }
    }
    private func send(_ event: String, payload: String) -> Bool {
        guard live else { return false }
        if event == "registered" { registered = true; return true }
        if event == "updateAlert" { return true } // No automatic update, UI URL opening, or source execution.
        guard event == "inited" else { return false }
        do {
            guard registered, candidate == nil, let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceFailure.initialization }
            candidate = try SourceCapability.validate(object)
            return true
        } catch { retire(reason: error); return false }
    }
    private func completeInitialization() {
        guard evaluated, registered, let candidate, context?.exception == nil, live else { return }
        lock.lock(); guard !retired else { lock.unlock(); return }; caps = candidate; lock.unlock()
        initGate?.finish(.success(())); initGate = nil
    }
    func resolve(song: Song, quality: AudioQuality) async throws -> PlaybackResource {
        let declared = capabilities
        guard let capability = declared[song.platform.rawValue], capability.actions.contains("musicUrl") else { throw SourceFailure.unsupported }
        // Never silently downgrade or claim that the URL's actual codec/bitrate has been verified.
        guard capability.qualitys.contains(quality.rawValue) else { throw SourceFailure.unsupported }
        let payload: [String: Any] = ["source": song.platform.rawValue, "action": "musicUrl",
                                    "info": ["type": quality.rawValue, "musicInfo": SourceLegacyInfo.make(song)]]
        return try await operation(seconds: requestTimeout) { [self] (gate: SourceDeadline<PlaybackResource>) in
            guard let ctx = context, evaluated, candidate != nil else { gate.finish(.failure(SourceFailure.initialization)); return }
            resultGate = gate; resultTicket = UUID().uuidString; requestedQuality = quality.rawValue
            // Value bridge, not serialized JSON masquerading as the request object.
            ctx.objectForKeyedSubscript("__tfRun")?.call(withArguments: [resultTicket, payload])
            if ctx.exception != nil { retire(reason: SourceFailure.script) }
        }
    }
    private func finish(_ ticket: String, ok: Bool, value: String) {
        guard live, ticket == resultTicket, let gate = resultGate else { return }
        resultGate = nil
        guard ok else { gate.finish(.failure(SourceFailure.script)); return }
        do {
            guard value.utf8.count <= 8192,
                  let raw = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String else { throw SourceFailure.result }
            let url = try SourceURLPolicy.url(raw, allowed: info.allowedHosts)
            gate.finish(.success(PlaybackResource(url: url, displayQuality: "音源：\(info.name) · 请求音质：\(requestedQuality)（未验证）")))
        } catch { gate.finish(.failure(error)) }
    }

    private func invoke(_ name: String, _ arguments: [Any]) {
        lock.lock(); guard !retired else { lock.unlock(); return }; executionDepth += 1; lock.unlock()
        defer { lock.lock(); executionDepth -= 1; lock.unlock() }
        context?.objectForKeyedSubscript(name)?.call(withArguments: arguments)
        if context?.exception != nil { retire(reason: SourceFailure.script) }
        else { completeInitialization() }
    }
    private func request(id: String, url: String, options: String) {
        guard live, options.utf8.count <= 2 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(options.utf8)) as? [String: Any] else {
            invoke("__tfDeliverHTTP", [id, "failed", ""]); return
        }
        do {
            let native = try http.request(url, allowed: info.allowedHosts, options: object) { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, self.live, self.requests.removeValue(forKey: id) != nil else { return }
                    if case .success(let reply) = result, let body = try? reply.json(),
                       let data = try? JSONSerialization.data(withJSONObject: body) {
                        self.invoke("__tfDeliverHTTP", [id, NSNull(), String(decoding: data, as: UTF8.self)])
                    } else { self.invoke("__tfDeliverHTTP", [id, "failed", ""]) }
                }
            }
            requests[id] = native
        } catch { invoke("__tfDeliverHTTP", [id, "failed", ""]) }
    }
    private func schedule(_ id: String, ms: Double) {
        guard ms.isFinite else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.live else { return }
                self.clearTimer(id); self.invoke("__tfDeliverTimer", [id])
            }
        }
        lock.lock()
        guard !retired, timers.count < 128 else { lock.unlock(); retire(reason: SourceFailure.tooLarge); return }
        timers[id]?.cancel(); timers[id] = item; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + min(60, max(0, ms / 1000)), execute: item)
    }
    private func clearTimer(_ id: String) {
        lock.lock(); let item = timers.removeValue(forKey: id); lock.unlock(); item?.cancel()
    }
    private static func crypto(_ operation: String, args: String) -> String {
        let failure = "{\"error\":true}"
        guard args.utf8.count <= 2 * 1024 * 1024,
              let values = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [Any] else { return failure }
        var value: Any
        switch operation {
        case "md5":
            guard let text = values.first as? String, text.utf8.count <= 262144 else { return failure }
            value = Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        case "random":
            guard let number = values.first as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue == Double(number.intValue), (0...65536).contains(number.intValue) else { return failure }
            var output = [UInt8](repeating: 0, count: number.intValue)
            if !output.isEmpty {
                let status = output.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
                guard status == errSecSuccess else { return failure }
            }
            value = output
        case "aes":
            guard values.count == 4, let input = byteArray(values[0]), let mode = values[1] as? String,
                  let key = byteArray(values[2]), key.count == kCCKeySizeAES128, let iv = byteArray(values[3]),
                  input.count <= 262144, ["aes-128-cbc", "aes-128-ecb"].contains(mode) else { return failure }
            let cbc = mode == "aes-128-cbc"
            guard cbc ? iv.count == kCCBlockSizeAES128 : input.count % kCCBlockSizeAES128 == 0 else { return failure }
            var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128), written = 0
            let capacity = output.count
            let status = output.withUnsafeMutableBytes { out in
                input.withUnsafeBytes { data in
                    key.withUnsafeBytes { secret in
                        iv.withUnsafeBytes { vector in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(cbc ? kCCOptionPKCS7Padding : kCCOptionECBMode),
                                    secret.baseAddress, key.count, cbc ? vector.baseAddress : nil,
                                    data.baseAddress, input.count, out.baseAddress, capacity, &written)
                        }
                    }
                }
            }
            guard status == kCCSuccess else { return failure }
            value = Array(output.prefix(written))
        default: return failure // RSA is explicitly unsupported, never fake successful output.
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["value": value]),
              let text = String(data: data, encoding: .utf8) else { return failure }
        return text
    }
    private static func byteArray(_ value: Any) -> [UInt8]? {
        guard let numbers = value as? [NSNumber], numbers.count <= 262144,
              numbers.allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue == Double($0.intValue) && (0...255).contains($0.intValue) }) else { return nil }
        return numbers.map { UInt8($0.intValue) }
    }
}
