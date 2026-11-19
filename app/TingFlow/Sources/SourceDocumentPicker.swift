import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Public UIKit import-as-copy picker. SwiftUI's fileImporter is deliberately not
/// involved: real providers may classify downloaded JavaScript inconsistently.
@MainActor
struct SourceDocumentPicker: UIViewControllerRepresentable {
    let completion: (Result<URL?, SourceImportFailure>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: SourceFileImport.pickerTypes, asCopy: true)
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
        // SwiftUI retains the coordinator for the entire presentation. The native
        // delegate is weak, so never create a short-lived delegate in makeUIViewController.
        coordinator.invalidate(); picker.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: ((Result<URL?, SourceImportFailure>) -> Void)?
        init(completion: @escaping (Result<URL?, SourceImportFailure>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard urls.count == 1, let url = urls.first else { finish(.failure(.notFile)); return }
            finish(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.success(nil)) }
        func invalidate() { completion = nil }
        private func finish(_ result: Result<URL?, SourceImportFailure>) {
            let callback = completion; completion = nil
            callback?(result) // nil before callback: re-entry/duplicate delegate events are harmless.
        }
    }
}
