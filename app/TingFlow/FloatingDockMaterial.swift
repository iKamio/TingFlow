import SwiftUI

struct FloatingDockMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        } else {
            glass(content)
        }
    }

    @ViewBuilder private func glass(_ content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            fallback(content)
        }
#else
        fallback(content)
#endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.7))
    }
}
