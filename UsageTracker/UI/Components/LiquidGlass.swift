import SwiftUI

extension View {
    /// Applies Liquid Glass on macOS 26+, falls back to ultra-thin material on macOS 14+.
    /// Reserve for chrome / navigation surfaces — not for content rows.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.modifier(LiquidGlassModifier(shape: shape, tint: tint))
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.18),
                                .white.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                )
        }
    }
}

@available(macOS 26.0, *)
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
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}

extension View {
    /// `.buttonStyle(.glass)` on macOS 26+, `.bordered` fallback.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
