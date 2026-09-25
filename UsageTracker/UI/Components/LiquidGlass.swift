import SwiftUI

extension View {
    /// Liquid Glass in `shape`, optionally tinted. Reserve for chrome and controls,
    /// never for content rows.
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(LiquidGlassModifier(shape: shape, tint: tint))
    }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        if let tint {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

/// Wraps adjacent glass elements so they share a sampling region and can morph cleanly.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}

extension View {
    /// `.buttonStyle(.glass)`: the secondary button everywhere.
    func glassButtonStyle() -> some View {
        buttonStyle(.glass)
    }

    /// `.buttonStyle(.glassProminent)`: the one primary action on a surface.
    func glassProminentButtonStyle() -> some View {
        buttonStyle(.glassProminent)
    }
}
