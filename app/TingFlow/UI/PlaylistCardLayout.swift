import SwiftUI

/// The parent supplies the width; neither decoded image dimensions nor text can
/// change the square allocated to artwork. Detail headers keep their own sizing.
struct PlaylistCover: View {
    let url: URL?
    var corner: CGFloat = 12
    let measurementID: String

    var body: some View {
        Rectangle().fill(.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay { ArtworkView(url: url, corner: corner) }
            .overlay {
                #if DEBUG
                if UIPolishFixture.enabled {
                    PlaylistCoverMeasurement(identifier: measurementID)
                        .allowsHitTesting(false)
                }
                #endif
            }
    }
}

#if DEBUG
/// A transparent, noninteractive AX anchor measures the *real* allocated cover
/// frame in UI tests. ArtworkView remains hidden from VoiceOver; Release has no
/// additional accessibility elements or testing harness.
private struct PlaylistCoverMeasurement: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "歌单封面"
        view.accessibilityIdentifier = identifier
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityIdentifier = identifier
    }
}
#endif
