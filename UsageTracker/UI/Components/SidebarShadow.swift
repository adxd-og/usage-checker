import SwiftUI

/// The floating sidebar's drop shadows (`OMGlass.sidebarShadows`), as a CSS `box-shadow`
/// paints them: outside the pane only. Shared by the dashboard and Settings sidebars.
enum OMSidebarShadowRules {
    /// The casters sit this far inside the mask's cutout. Both edges are anti-aliased, so
    /// partial coverage on each would leave residual black on the edge pixels, a dark
    /// fringe against the backdrop.
    static let casterInset: CGFloat = 1

    /// How far past the pane the mask reaches: three shadow radii (the Gaussian's visible
    /// tail) plus the offset, for the widest shadow. The halo is clipped only past that.
    static func reach(_ shadows: [OMShadow]) -> CGFloat {
        shadows
            .map { 3 * OMGlassRules.shadowRadius(cssBlur: $0.blur) + abs($0.y) }
            .max() ?? 0
    }
}

/// Casts the sidebar's shadows for the environment's scheme outside `corner`'s shape.
/// System glass draws no recipe shadow, and a shadow on the glass itself would shade every
/// glyph on it. So opaque shapes behind the glass cast the shadows, and a reverse mask
/// removes everything inside the pane's shape. The casters add nothing under the glass:
/// the backdrop and the window's one tint show through it untouched.
struct OMSidebarShadow: ViewModifier {
    let corner: OMCornerContext
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background { casters }
    }

    private var casters: some View {
        let shadows = OMGlass.sidebarShadows(scheme: colorScheme)
        let shape = OMCornerShape(corner)
        let reach = OMSidebarShadowRules.reach(shadows)
        return ZStack {
            ForEach(Array(shadows.enumerated()), id: \.offset) { _, shadow in
                // Opaque only to give the shadow its silhouette; the mask removes it.
                shape
                    .inset(by: OMSidebarShadowRules.casterInset)
                    .fill(Color.black)
                    .shadow(
                        color: shadow.color.color,
                        radius: OMGlassRules.shadowRadius(cssBlur: shadow.blur),
                        x: 0,
                        y: shadow.y
                    )
            }
        }
        .mask {
            ZStack {
                Rectangle().padding(-reach)
                shape.blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The floating sidebar's drop shadows outside `corner`'s shape; applied after the
    /// pane's `.omGlass(.sidebar, in:)`.
    func omSidebarShadow(corner: OMCornerContext) -> some View {
        modifier(OMSidebarShadow(corner: corner))
    }
}
