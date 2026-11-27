import SwiftUI
import UIKit

/// The only shareable content is the Core allowlisted value model's text.
/// Opening this sheet never reads or writes the clipboard.
@MainActor struct ServerArtworkDiagnosticView: View {
    let diagnostic: ServerArtworkDiagnostic
    let accessibilityID: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(diagnostic.text)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .accessibilityIdentifier(accessibilityID + ".summary")
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("封面诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("复制诊断") {
                        UIPasteboard.general.string = diagnostic.text
                        copied = true
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier(accessibilityID + ".copy")
                    .accessibilityValue(copied ? "已复制" : "尚未复制")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier(accessibilityID + ".close")
                }
            }
            .onAppear { copied = false }
            .onChange(of: diagnostic) { _ in copied = false }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
