import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Public UIKit import-as-copy picker. SwiftUI's fileImporter is deliberately not
/// involved: real providers may classify downloaded JavaScript inconsistently.
@MainActor
struct SourceDocumentPicker: UIViewControllerRepresentable {
    // The page session, not the transient sheet, strongly owns this coordinator.
    let coordinator: Coordinator

    func makeCoordinator() -> Coordinator { coordinator }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = SourceNativeDocumentPickerController(forOpeningContentTypes: SourceFileImport.pickerTypes, asCopy: true)
        picker.importCoordinator = context.coordinator
        context.coordinator.attach(picker)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        #if DEBUG
        if SourceImportUIFixture.enabled { picker.directoryURL = try? SourceImportUIFixture.prepare() }
        #endif
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) { }
    static func dismantleUIViewController(_ picker: UIDocumentPickerViewController, coordinator: Coordinator) {
        // Native dismissal/dismantling may precede didPickDocumentsAt. The
        // external session releases the weak delegate after handoff or real exit.
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: ((Result<URL?, SourceImportFailure>) -> Void)?
        private weak var picker: UIDocumentPickerViewController?
        init(completion: @escaping (Result<URL?, SourceImportFailure>) -> Void) { self.completion = completion }
        func attach(_ value: UIDocumentPickerViewController) { picker = value }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard urls.count == 1, let url = urls.first else { finish(.failure(.notFile)); return }
            finish(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.success(nil)) }
        func interactiveDismissed() { finish(.success(nil)) }
        func invalidate() {
            completion = nil; picker?.delegate = nil
            (picker as? SourceNativeDocumentPickerController)?.importCoordinator = nil
            picker = nil
        }
        private func finish(_ result: Result<URL?, SourceImportFailure>) {
            let callback = completion; completion = nil
            callback?(result) // nil before callback: re-entry/duplicate delegate events are harmless.
        }
    }
}

/// Observe completed USER dismissal without replacing SwiftUI's presentation
/// delegate. Programmatic selection dismissal is not proof of cancellation.
@MainActor private final class SourceNativeDocumentPickerController: UIDocumentPickerViewController {
    weak var importCoordinator: SourceDocumentPicker.Coordinator?
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let chain = sourceImportAncestors(self)
        guard chain.contains(where: { $0.isBeingDismissed }),
              let transition = chain.compactMap({ $0.transitionCoordinator }).first,
              transition.isInteractive else { return }
        let receiver = importCoordinator
        transition.animate(alongsideTransition: nil) { context in
            if !context.isCancelled { receiver?.interactiveDismissed() }
        }
    }
}

@MainActor private func sourceImportAncestors(_ controller: UIViewController) -> [UIViewController] {
    var result = [controller]
    var next = controller.parent
    while let value = next { result.append(value); next = value.parent }
    return result
}

/// A zero-sized child observes the EXISTING SwiftUI page's UIKit ownership. It
/// neither presents another controller nor modifies navigation delegates/stacks.
/// Visibility alone (including full-screen child sheets) never ends the owner.
@MainActor struct SourceImportOwnerObserver: UIViewControllerRepresentable {
    let session: SourceImportSession
    let dismiss: () -> Void
    func makeUIViewController(context: Context) -> Controller {
        Controller(session: session, dismiss: dismiss)
    }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.dismiss = dismiss }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.removed() }

    @MainActor final class Controller: UIViewController {
        private let token = UUID()
        private weak var session: SourceImportSession?
        var dismiss: () -> Void
        private weak var page: UIViewController?
        private weak var navigation: UINavigationController?
        private weak var presentedRoot: UIViewController?
        private weak var ownerTabController: UITabBarController?
        private weak var tabBranch: UIViewController?
        private var hadNavigation = false
        private var wasPresented = false
        private var removalInProgress = false
        private var transitionPending = false
        init(session: SourceImportSession, dismiss: @escaping () -> Void) {
            self.session = session; self.dismiss = dismiss
            super.init(nibName: nil, bundle: nil)
            session.registerOwner(token)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() {
            let value = UIView(frame: .zero); value.isUserInteractionEnabled = false
            value.isAccessibilityElement = false; view = value
        }
        private func captureOwner() {
            let chain = sourceImportAncestors(self)
            if let nav = navigationController,
               let host = chain.first(where: { node in nav.viewControllers.contains(where: { $0 === node }) }) {
                navigation = nav; page = host; hadNavigation = true
                if let tabs = nav.tabBarController {
                    ownerTabController = tabs
                    tabBranch = chain.first(where: { node in tabs.viewControllers?.contains(where: { $0 === node }) == true })
                }
            }
            if let root = chain.last(where: { $0.presentingViewController != nil }) {
                presentedRoot = root; wasPresented = true
            }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); captureOwner()
            removalInProgress = false
            session?.ownerAppeared(token)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated); captureOwner()
            let chain = sourceImportAncestors(self)
            removalInProgress = chain.contains(where: { $0.isMovingFromParent || $0.isBeingDismissed })
            guard let transition = chain.compactMap({ $0.transitionCoordinator }).first else { return }
            let removal = removalInProgress
            transitionPending = true
            let accepted = transition.animate(alongsideTransition: nil) { [self] context in
                transitionPending = false
                guard !context.isCancelled else { removalInProgress = false; return }
                checkExit(force: removal, disposed: false)
            }
            if !accepted { transitionPending = false }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if !transitionPending { checkExit(force: removalInProgress, disposed: false) }
        }
        private func topologyHasExited() -> Bool {
            var route = SourceImportOwnerRoute()
            route.hadNavigation = hadNavigation
            if hadNavigation {
                if let nav = navigation, let host = page {
                    route.navigationContainsPage = nav.viewControllers.contains(where: { $0 === host })
                    route.pageIsNavigationTop = nav.topViewController === host
                } else { route.navigationContainsPage = false }
            }
            route.wasPresented = wasPresented
            if wasPresented {
                route.ownerStillPresented = presentedRoot.map { $0.presentingViewController != nil || $0.isBeingPresented } ?? false
            }
            if let tabs = ownerTabController, let branch = tabBranch {
                route.hadTab = true; route.ownerTabSelected = tabs.selectedViewController === branch
            }
            return route.shouldExit()
        }
        private func checkExit(force: Bool, disposed: Bool) {
            guard force || topologyHasExited() else { return }
            if session?.ownerExited(token, disposed: disposed) == true { dismiss() }
        }
        func removed() {
            captureOwner()
            let chain = sourceImportAncestors(self)
            if let transition = chain.compactMap({ $0.transitionCoordinator }).first {
                let removal = removalInProgress
                let accepted = transition.animate(alongsideTransition: nil) { [self] context in
                    guard !context.isCancelled else { return }
                    checkExit(force: removal, disposed: true)
                }
                if accepted { return }
            }
            // Post-transaction topology check, not a timed sleep. A replacement
            // observer registers a new token before this check. A cancelled pop
            // still owns the same top controller and therefore does not cancel.
            DispatchQueue.main.async { [self] in checkExit(force: false, disposed: true) }
        }
    }
}
