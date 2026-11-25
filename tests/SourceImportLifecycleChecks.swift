import Foundation

/// Compile on the native check runner with SourceFileImport.swift and
/// SourceImportSession.swift. No UIKit, network, clipboard or JS evaluation.
@main @MainActor struct SourceImportLifecycleChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        let url = URL(fileURLWithPath: "/temporary/lifecycle-source.JS")
        var registration = SourceImportOwnerRegistration()
        let oldObserver = UUID(), replacement = UUID()
        registration.register(oldObserver)
        check(registration.owns(oldObserver), "initial structural observer owns session")
        registration.register(replacement)
        check(!registration.owns(oldObserver) && registration.owns(replacement), "old dismantle cannot dispose a replacement observer")
        var route = SourceImportOwnerRoute()
        route.hadNavigation = true
        check(!route.shouldExit(), "child sheet does not change page navigation ownership")
        route.pageIsNavigationTop = false
        check(route.shouldExit() && !route.shouldExit(transitionCancelled: true), "committed push cancels; cancelled transition does not")
        route.pageIsNavigationTop = true; route.navigationContainsPage = false
        check(route.shouldExit() && !route.shouldExit(transitionCancelled: true), "committed pop/disposal cancels; cancelled pop does not")
        route.navigationContainsPage = true; route.wasPresented = true
        check(!route.shouldExit(), "nested child cover leaves root presentation owned")
        route.ownerStillPresented = false
        check(route.shouldExit(), "dismissed root presentation ends owner")
        route.ownerStillPresented = true; route.hadTab = true; route.ownerTabSelected = false
        check(route.shouldExit(), "committed tab departure ends page ownership")
        for resultFirst in [true, false] {
            var state = SourceImportHandoff()
            var policy = SourcePickerPolicy()
            let ticket = policy.begin()
            check(state.begin(ticket), "begin current picker")
            check(state.presentationLocked, "single presentation owner locked")
            check(!state.begin(UUID()), "cannot replace an unresolved presentation")
            if resultFirst {
                check(state.receive(.success(url), ticket: ticket), "result arrives first")
                check(state.consume() == nil, "no read before dismissal")
                check(state.presentationLocked, "result does not unlock a dismissing sheet")
                check(state.dismissed(ticket: ticket), "dismiss arrives second")
            } else {
                check(state.dismissed(ticket: ticket), "dismiss arrives first")
                check(state.consume() == nil, "dismissal is not proof of cancellation")
                check(state.presentationLocked, "retain late delegate and presentation lock")
                check(state.receive(.success(url), ticket: ticket), "late result remains accepted")
            }
            check(state.consume() != nil && policy.selected(ticket), "one handoff starts one read")
            check(!state.presentationLocked && state.permitsReadCommit(ticket), "handoff permits current read only")
            check(state.consume() == nil && !state.receive(.success(url), ticket: ticket), "duplicate outcome ignored")
            check(!policy.selected(ticket) && policy.finish(ticket), "unchanged policy commits once")
            check(!policy.finish(ticket), "duplicate read cannot commit")
            state.ownerEvent(.childCovered)
            state.ownerEvent(.transitionCancelled)
            check(state.ownerActive && state.permitsReadCommit(ticket), "child cover and cancelled navigation preserve read")
            state.ownerEvent(.committedExit)
            check(!state.ownerActive && !state.permitsReadCommit(ticket), "committed navigation suppresses late read")
            check(!state.receive(.success(url), ticket: ticket) && !state.dismissed(ticket: ticket), "exit suppresses late native events")
            state.ownerAppeared()
            let next = policy.begin()
            check(state.begin(next) && !state.receive(.success(url), ticket: ticket), "re-entry uses a fresh ticket")
            state.ownerEvent(.disposed)
            check(!state.ownerActive && !state.begin(UUID()), "disposed root owner cannot present or import")
        }
        for resultFirst in [true, false] {
            var state = SourceImportHandoff()
            let ticket = UUID(); check(state.begin(ticket), "begin native cancel case")
            if resultFirst { state.receive(.success(nil), ticket: ticket) }
            state.dismissed(ticket: ticket)
            if !resultFirst { state.receive(.success(nil), ticket: ticket) }
            if case .success(let selected)? = state.consume() {
                check(selected == nil && !state.permitsReadCommit(ticket), "explicit cancel settles idle without failure")
            } else { preconditionFailure("native cancel lost") }
            check(state.consume() == nil && !state.presentationLocked, "cancel completes once and unlocks")
        }
        var failed = SourceImportHandoff()
        let failedTicket = UUID(); check(failed.begin(failedTicket), "begin delegate failure")
        failed.receive(.failure(.notFile), ticket: failedTicket); failed.dismissed(ticket: failedTicket)
        if case .failure(let error)? = failed.consume() { check(error == .notFile, "delegate failure survives dismissal") }
        else { preconditionFailure("delegate failure lost") }
        check(!failed.permitsReadCommit(failedTicket), "failed outcome never authorizes storage")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourceLifecycleChecks-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let wrong = root.appendingPathComponent("wrong.txt")
        try Data("not JavaScript".utf8).write(to: wrong)
        do { _ = try await SourceFileImport.read(wrong); preconditionFailure("txt accepted") }
        catch { check(error as? SourceImportFailure == .fileType, "real local txt yields existing fail-alert error") }
        let bytes = Data("/* @name Lifecycle-only */\nthrow Error('must-not-execute');".utf8)
        let local = root.appendingPathComponent("local.JS"); try bytes.write(to: local)
        let copied = try await SourceFileImport.read(local)
        check(copied.data == bytes && copied.filename == "local.JS", "real bounded read preserves bytes without evaluation")

        // A provider already in flight may finish after exit. Synchronize worker
        // entry explicitly; no sleep is used to establish the ordering.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var reading = SourceImportHandoff()
        let readTicket = UUID(); check(reading.begin(readTicket), "begin in-flight read")
        reading.receive(.success(local), ticket: readTicket); reading.dismissed(ticket: readTicket)
        check(reading.consume() != nil && reading.permitsReadCommit(readTicket), "current read initially authorized")
        let task = Task {
            try await SourceFileImport.performRead(timeout: 2) { _ in
                entered.signal(); _ = release.wait(timeout: .now() + 2)
                return SourceImportFile(data: bytes, filename: "late.JS")
            }
        }
        let began = await waitFor(entered)
        check(began, "provider has entered before cancellation")
        reading.ownerEvent(.disposed); task.cancel()
        do { _ = try await task.value; preconditionFailure("disposed read succeeded") }
        catch { check(SourceImportFailure.isCancellation(error), "owner teardown cancels pending read") }
        release.signal()
        check(!reading.permitsReadCommit(readTicket), "late provider cannot import into disposed owner")

        let stalled = DispatchSemaphore(value: 0)
        do {
            _ = try await SourceFileImport.performRead(timeout: 0.03) { _ in
                _ = stalled.wait(timeout: .now() + 2)
                return SourceImportFile(data: bytes, filename: "timed-out.JS")
            }
            preconditionFailure("deadline accepted late data")
        } catch { check(error as? SourceImportFailure == .timedOut, "existing independent read deadline preserved") }
        stalled.signal()
        check(SourceFileImport.readTimeout == 15 && SourceFileImport.maximumBytes == 1024 * 1024, "unchanged deadline and byte limit")
        print("PASS: \(count) source import lifecycle/ordering/owner/cancel/local-file checks; no script execution")
    }
    private static func waitFor(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }
}
