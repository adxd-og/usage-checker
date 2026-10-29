import SwiftUI

/// What the island controller and the island's root view share (notch-island spec 2026-10-29
/// § 3.1): the geometry of the current open and the content's measured size. Only the root
/// view observes it, so a content-height change redraws the shape, never the content.
@MainActor
final class IslandModel: ObservableObject {
    @Published var geometry: IslandGeometry?
    @Published var contentSize: CGSize = .zero
}

/// The island window's whole content: on a notched display the black shape (always dark,
/// § 3.1 Appearance), and today's popover content on top of it, unchanged, centred under the
/// notch strip (§ 5, P1). The panel has no shape of its own: the content's rounded body is
/// the panel, with the shadow NSPopover drew around it (ruling R14).
struct IslandRootView<Content: View>: View {
    @ObservedObject var model: IslandModel
    let content: Content

    var body: some View {
        if let geometry = model.geometry {
            let size = model.contentSize
            let origin = geometry.contentOrigin(contentSize: size)
            ZStack(alignment: .topLeading) {
                if geometry.kind == .island {
                    IslandBodyShape(geometry: geometry, contentSize: size)
                        .fill(Color.black)
                }
                content
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { measured in
                        model.contentSize = measured
                    }
                    .shadow(color: .black.opacity(geometry.kind == .panel ? 0.22 : 0), radius: 10, y: 4)
                    .offset(x: origin.x, y: origin.y)
            }
            .frame(width: geometry.windowSize.width, height: geometry.windowSize.height, alignment: .topLeading)
            // The window overlaps the notch: no safe area, the geometry places everything.
            .ignoresSafeArea()
        }
    }
}

/// `IslandGeometry`'s path as a shape. SwiftUI proposes the whole window, which is the space
/// the geometry's coordinates are in.
private struct IslandBodyShape: Shape {
    let geometry: IslandGeometry
    let contentSize: CGSize

    nonisolated func path(in rect: CGRect) -> Path {
        geometry.path(contentSize: contentSize)
    }
}
