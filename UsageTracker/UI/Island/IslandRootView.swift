import SwiftUI

/// What the island controller and the island's root view share (notch-island spec 2026-10-29
/// § 3.1, § 3.2): the geometry of the current open, the content's measured size, and the
/// stage `IslandTransition` has put the content at. Only the root view observes it, so a
/// content-height change or a stage change redraws the shell, never the content itself.
@MainActor
final class IslandModel: ObservableObject {
    @Published var geometry: IslandGeometry?
    @Published var contentSize: CGSize = .zero
    @Published var stage: IslandTransition.Stage = .closed
}

/// The shape's progress (0 the notch, 1 open), set on every frame of the motion. Only the
/// shape and its mask observe it, so a 120 Hz progress never re-renders the content.
@MainActor
final class IslandShapeModel: ObservableObject {
    @Published var progress: Double = 0
}

/// The island window's whole content (§ 3.1, § 3.2). On a display with an island (a notch, or the pill on one without): the black shape
/// at the motion's current progress, always dark, and the island's content (`PopoverView`)
/// on top of it, filling the body under the notch strip and masked by the shape, so
/// nothing shows outside the
/// island while it grows and shrinks. The panel has no shape of its own: the content's
/// rounded body is the panel, with the shadow NSPopover drew around it (P1 ruling R14), and
/// it fades in place. The content comes in and goes out as `IslandTransition.Stage` says, is
/// clickable and read by VoiceOver only while open, and under Reduce Motion the whole window
/// cross-fades.
struct IslandRootView<Content: View>: View {
    @ObservedObject var model: IslandModel
    let shape: IslandShapeModel
    /// The ear's head on its way to the pet (§ 3.6); only its layer observes it.
    let morph: IslandEarMorphModel
    let content: Content
    /// Reduce Transparency: the panel's body goes opaque (`IslandSurfaceRules`).
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let geometry = model.geometry {
            let size = model.contentSize
            let origin = geometry.contentOrigin(contentSize: size)
            let stage = model.stage
            let rise = IslandMotion.rise(for: geometry.kind)
            let backing = IslandSurfaceRules.backing(kind: geometry.kind, reduceTransparency: reduceTransparency)
            ZStack(alignment: .topLeading) {
                if backing == .black {
                    IslandShapeLayer(model: shape, geometry: geometry, contentSize: size)
                }
                // The content stage: what comes in after the shape and goes out before it.
                ZStack(alignment: .topLeading) {
                    // Reduce Transparency: the panel's body is opaque whatever its content draws.
                    if backing == .windowBackground {
                        IslandBodyShape(geometry: geometry, contentSize: size, progress: 1)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    }
                    content
                        // Tiles and cards nearly transparent on the island, the panel's own
                        // elsewhere (§ 3.1, Surfaces on the island; `OMPopoverSurface.style`).
                        .environment(\.popoverSurfaceOnIsland, IslandSurfaceRules.surfacesOnIsland(kind: geometry.kind))
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { proxy in
                            proxy.size
                        } action: { measured in
                            model.contentSize = measured
                        }
                        .shadow(color: .black.opacity(geometry.kind == .panel ? 0.22 : 0), radius: 10, y: 4)
                        .offset(x: origin.x, y: origin.y)
                }
                // In fading (on the island rising 8 pt inside the shape), out the same way back
                // (§ 3.2). The panel's body never moves, so it is drawn where it takes the mouse.
                .animation(stage.contentFade?.animation) { view in
                    view
                        .opacity(stage.contentShown ? 1 : 0)
                        .offset(y: stage.contentShown ? 0 : rise)
                }
                // Clickable and read by VoiceOver only while open (§ 3.2).
                .allowsHitTesting(stage.interactive)
                .accessibilityHidden(!stage.interactive)
            }
            .frame(width: geometry.windowSize.width, height: geometry.windowSize.height, alignment: .topLeading)
            // On the island nothing shows outside the shape as it grows and shrinks.
            .mask {
                if geometry.kind == .island {
                    IslandShapeLayer(model: shape, geometry: geometry, contentSize: size)
                } else {
                    Rectangle()
                }
            }
            // Above the mask: the head starts beside the notch, outside the shape as it grows.
            .overlay(alignment: .topLeading) {
                IslandEarMorphLayer(model: morph)
            }
            // Reduce Motion: the whole window cross-fades instead (§ 3.2).
            .animation(stage.islandFade?.animation) { view in
                view.opacity(stage.islandShown ? 1 : 0)
            }
            // The window overlaps the notch: no safe area, the geometry places everything.
            .ignoresSafeArea()
        }
    }
}

/// The ear's head as it grows into the habitat pet (§ 3.6): window coordinates, no hit area.
private struct IslandEarMorphLayer: View {
    @ObservedObject var model: IslandEarMorphModel

    var body: some View {
        if let frame = model.frame, let image = model.image {
            Image(decorative: image, scale: model.backingScale)
                .resizable()
                .interpolation(.none)
                .frame(width: frame.rect.width, height: frame.rect.height)
                .opacity(frame.opacity)
                .offset(x: frame.rect.minX, y: frame.rect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The black shape at the motion's progress: the island's fill, and the mask over its content.
private struct IslandShapeLayer: View {
    @ObservedObject var model: IslandShapeModel
    let geometry: IslandGeometry
    let contentSize: CGSize

    var body: some View {
        IslandBodyShape(geometry: geometry, contentSize: contentSize, progress: model.progress)
            .fill(Color.black)
    }
}

/// `IslandGeometry`'s path at a progress, as a shape. SwiftUI proposes the whole window,
/// which is the space the geometry's coordinates are in.
private struct IslandBodyShape: Shape {
    let geometry: IslandGeometry
    let contentSize: CGSize
    let progress: Double

    nonisolated func path(in rect: CGRect) -> Path {
        geometry.path(contentSize: contentSize, progress: progress)
    }
}
