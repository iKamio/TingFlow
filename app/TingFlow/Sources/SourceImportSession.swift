import Foundation

/// Pure counterparts of the UIKit observer's ownership and replacement checks.
struct SourceImportOwnerRegistration {
    private(set) var token: UUID?
    mutating func register(_ value: UUID) { token = value }
    func owns(_ value: UUID) -> Bool { token == value }
}
struct SourceImportOwnerRoute {
    var hadNavigation = false
    var navigationContainsPage = true
    var pageIsNavigationTop = true
    var wasPresented = false
    var ownerStillPresented = true
    var hadTab = false
    var ownerTabSelected = true
    func shouldExit(transitionCancelled: Bool = false) -> Bool {
        guard !transitionCancelled else { return false }
        return (hadNavigation && (!navigationContainsPage || !pageIsNavigationTop)) ||
            (wasPresented && !ownerStillPresented) || (hadTab && !ownerTabSelected)
    }
}

/// Selection and presentation completion are independent signals. This model is
/// Foundation-only so both callback orders and owner invalidation can be checked
/// without a picker, provider, SwiftUI or JavaScript engine.
struct SourceImportHandoff {
    enum OwnerEvent { case childCovered, transitionCancelled, committedExit, disposed }
    private(set) var ownerActive = true
    private(set) var ticket: UUID?
    private(set) var didDismiss = false
    private(set) var outcome: Result<URL?, SourceImportFailure>?
    private(set) var consumed = false
    var presentationLocked: Bool { ticket != nil && !consumed }

    mutating func begin(_ value: UUID) -> Bool {
        guard ownerActive, !presentationLocked else { return false }
        ticket = value; didDismiss = false; outcome = nil; consumed = false
        return true
    }
    @discardableResult mutating func receive(_ result: Result<URL?, SourceImportFailure>, ticket value: UUID) -> Bool {
        guard ownerActive, ticket == value, !consumed, outcome == nil else { return false }
        outcome = result; return true
    }
    @discardableResult mutating func dismissed(ticket value: UUID) -> Bool {
        guard ownerActive, ticket == value, !consumed else { return false }
        didDismiss = true; return true
    }
    mutating func consume() -> Result<URL?, SourceImportFailure>? {
        guard ownerActive, didDismiss, !consumed, let outcome else { return nil }
        consumed = true; return outcome
    }
    func permitsReadCommit(_ value: UUID) -> Bool {
        guard ownerActive, ticket == value, consumed, let outcome else { return false }
        if case .success(let url) = outcome { return url != nil }
        return false
    }
    mutating func cancel() {
        ticket = nil; didDismiss = false; outcome = nil; consumed = false
    }
    mutating func ownerEvent(_ event: OwnerEvent) {
        switch event {
        case .childCovered, .transitionCancelled: break
        case .committedExit, .disposed: ownerActive = false; cancel()
        }
    }
    mutating func ownerAppeared() { ownerActive = true }
}

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// No script evaluation occurs in this session. Store commits remain synchronous
// on the main actor, immediately after the owner/ticket/cancellation checks.
enum SourceImportStage { case idle, selecting, reading, failed(String) }

@MainActor final class SourceImportSession: ObservableObject {
    @Published var stage: SourceImportStage = .idle
    @Published var notice: String?
    @Published var afterDismissNotice: String?
    @Published private(set) var presentationID: String?
    @Published private(set) var handoff = SourceImportHandoff()
    @Published private(set) var policy = SourcePickerPolicy()
    private let store: SourceStore
    private var pickerCoordinator: SourceDocumentPicker.Coordinator?
    private var importTask: Task<Void, Never>?
    private var ownerRegistration = SourceImportOwnerRegistration()
    private let importedMessage = "音源已导入并隔离；尚未运行。请阅读脚本、确认信任并只授权所需域名。"
    var isReading: Bool { policy.phase == .reading }
    var presentationLocked: Bool { presentationID != nil }
    var ownerActive: Bool { handoff.ownerActive }
    init(store: SourceStore) { self.store = store }
    deinit { importTask?.cancel() }

    func beginPicker(dismiss: @escaping () -> Void) -> UUID? {
        guard ownerActive, !isReading, !presentationLocked else { return nil }
        cancelRead(); afterDismissNotice = nil; notice = nil
        let ticket = policy.begin()
        guard handoff.begin(ticket) else { return nil }
        stage = .selecting; presentationID = "picker-\(ticket)"
        pickerCoordinator = SourceDocumentPicker.Coordinator { [weak self] result in
            guard let self, self.handoff.receive(result, ticket: ticket) else { return }
            dismiss()
            self.drainPicker()
        }
        return ticket
    }
    func coordinator(for ticket: UUID) -> SourceDocumentPicker.Coordinator? {
        guard ownerActive, handoff.ticket == ticket, !handoff.consumed else { return nil }
        return pickerCoordinator
    }
    func beginPresentation(_ id: String) -> Bool {
        guard ownerActive, !isReading, !presentationLocked else { return false }
        cancelRead(); stage = .idle; afterDismissNotice = nil
        presentationID = id; return true
    }
    func acceptsPresentation(_ id: String) -> Bool { ownerActive && presentationID == id }
    func importPasted(_ file: SourceImportFile, presentation id: String) throws {
        guard acceptsPresentation(id) else { throw CancellationError() }
        try store.importScript(file.data, filename: file.filename)
        stage = .idle; afterDismissNotice = importedMessage
    }
    func modalDismissed() {
        guard ownerActive, let id = presentationID else { return }
        if let ticket = handoff.ticket, id == "picker-\(ticket)" {
            handoff.dismissed(ticket: ticket)
            drainPicker() // A dismissal alone must not invalidate a late delegate.
        } else {
            presentationID = nil
            if let message = afterDismissNotice { afterDismissNotice = nil; notice = message }
        }
    }
    private func drainPicker() {
        guard let ticket = handoff.ticket, let result = handoff.consume() else { return }
        // Invalidate only AFTER both signals have been consumed. Ordinary
        // representable dismantling must not disconnect an unresolved delegate.
        pickerCoordinator?.invalidate(); pickerCoordinator = nil
        presentationID = nil
        switch result {
        case .success(let url):
            guard let url, policy.selected(ticket) else { cancelRead(); stage = .idle; return }
            stage = .reading
            importTask = Task { @MainActor [weak self] in
                do {
                    let file = try await SourceFileImport.read(url)
                    try Task.checkCancellation()
                    guard let self, self.handoff.permitsReadCommit(ticket), self.policy.finish(ticket) else { return }
                    self.importTask = nil
                    try self.store.importScript(file.data, filename: file.filename)
                    self.stage = .idle; self.notice = self.importedMessage
                } catch {
                    guard let self, self.handoff.permitsReadCommit(ticket), ticket == self.policy.id else { return }
                    _ = self.policy.finish(ticket); self.importTask = nil
                    if SourceImportFailure.isCancellation(error) { self.stage = .idle; return }
                    let message = (error as? SourceImportFailure)?.localizedDescription ??
                        (error as? SourceFailure)?.localizedDescription ?? SourceFailure.storage.localizedDescription
                    self.stage = .failed(message); self.notice = message
                }
            }
        case .failure(let error):
            policy.cancel(); stage = .failed(error.localizedDescription); notice = error.localizedDescription
        }
    }
    func cancelRead() {
        policy.cancel(); handoff.cancel(); importTask?.cancel(); importTask = nil
    }
    // Observer replacements share this session. An old dismantled observer may
    // never dispose the new registration during a cancelled/rebuilt transition.
    func registerOwner(_ token: UUID) { ownerRegistration.register(token) }
    func ownerAppeared(_ token: UUID) {
        guard ownerRegistration.owns(token) else { return }
        handoff.ownerAppeared()
    }
    @discardableResult func ownerExited(_ token: UUID, disposed: Bool = false) -> Bool {
        guard ownerRegistration.owns(token), ownerActive else { return false }
        handoff.ownerEvent(disposed ? .disposed : .committedExit)
        policy.cancel(); importTask?.cancel(); importTask = nil
        pickerCoordinator?.invalidate(); pickerCoordinator = nil
        presentationID = nil; stage = .idle; afterDismissNotice = nil; notice = nil
        return true
    }
}
#endif
