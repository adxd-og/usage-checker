import SwiftUI

/// The 3.0 window background (`OMPalette.windowBackdrop`) for the current appearance,
/// painted edge to edge. Decoration only, so VoiceOver skips it. Screens adopt it in
/// their own packages; nothing paints it yet.
struct OMWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let backdrop = OMPalette.windowBackdrop(scheme: colorScheme)
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(backdrop.base.color))
            // Bottom layer first: CSS's first gradient is its top layer (`paintOrder`).
            for pool in backdrop.paintOrder {
                var layer = context
                layer.translateBy(x: pool.x * size.width, y: pool.y * size.height)
                // A CSS ellipse: a circle of radiusX, squashed to radiusY.
                layer.scaleBy(x: 1, y: pool.radiusY / pool.radiusX)
                let radius = pool.radiusX
                let gradient = Gradient(stops: [
                    .init(color: pool.color.color, location: 0),
                    .init(color: pool.color.withOpacity(0).color, location: pool.fadeStop),
                ])
                layer.fill(
                    Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: radius)
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview("Window background") {
    HStack(spacing: 0) {
        OMWindowBackground().environment(\.colorScheme, .dark)
        OMWindowBackground().environment(\.colorScheme, .light)
    }
    .frame(width: 880, height: 460)
}
