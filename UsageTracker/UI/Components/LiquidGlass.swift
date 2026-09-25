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

// MARK: - 3.0 glass surfaces (liquid-glass spec § Design → Tokens and Components)

/// One stop of a surface's 1 px inner edge light.
struct OMEdgeStop: Equatable, Sendable {
    let color: OMRGBA
    let location: CGFloat
}

/// The rules the glass surfaces render by; `OMGlassSurface` only applies them.
enum OMGlassRules {
    /// Chrome, pane and control track are the system's glass, tinted with the
    /// recipe's fill. The raised pill is a plain fill with a shadow: it always sits
    /// on a glass track or pane, and two glass layers merge or muddy each other.
    static func usesSystemGlass(_ kind: OMGlassKind) -> Bool {
        kind != .raisedPill
    }

    /// CSS `box-shadow` blur → SwiftUI shadow radius, a Gaussian radius of about half.
    static func shadowRadius(cssBlur: CGFloat) -> CGFloat {
        cssBlur / 2
    }

    /// The 1 px inner edge light, top to bottom: the top highlight fading out by
    /// mid-height, the bottom one fading in from there, each in its own colour so the
    /// fade never passes through grey. Empty when the recipe has neither.
    static func edgeHighlightStops(_ recipe: OMGlassRecipe) -> [OMEdgeStop] {
        var stops: [OMEdgeStop] = []
        if let top = recipe.topHighlight {
            stops.append(OMEdgeStop(color: top, location: 0))
            stops.append(OMEdgeStop(color: top.withOpacity(0), location: 0.5))
        }
        if let bottom = recipe.bottomHighlight {
            stops.append(OMEdgeStop(color: bottom.withOpacity(0), location: 0.5))
            stops.append(OMEdgeStop(color: bottom, location: 1))
        }
        return stops
    }
}

extension View {
    /// The glass surface `kind` in `shape`. A control whose rule names its surface (an
    /// `OMGlassKind` static) renders through this, so changing the rule changes the view.
    func omGlass<S: InsettableShape>(_ kind: OMGlassKind, in shape: S) -> some View {
        modifier(OMGlassSurface(kind: kind, shape: shape))
    }

    /// Popover body, window chrome and the dashboard and Settings sidebars.
    func chromeGlass<S: InsettableShape>(in shape: S) -> some View {
        omGlass(.chrome, in: shape)
    }

    /// Glass over the content fill: the dashboard cards.
    func paneGlass<S: InsettableShape>(in shape: S) -> some View {
        omGlass(.pane, in: shape)
    }

    /// The capsule track under a segmented control.
    func controlTrackGlass<S: InsettableShape>(in shape: S) -> some View {
        omGlass(.controlTrack, in: shape)
    }

    /// The selected segment or nav item, raised on its track or pane.
    func raisedPill<S: InsettableShape>(in shape: S) -> some View {
        omGlass(.raisedPill, in: shape)
    }
}

/// Draws one glass surface from its recipe for the current appearance: system glass
/// tinted with the fill (or, for the raised pill, the fill and its shadow), a 1 px
/// border and the inner edge light.
private struct OMGlassSurface<S: InsettableShape>: ViewModifier {
    let kind: OMGlassKind
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let recipe = OMGlass.recipe(kind, scheme: colorScheme)
        let stops = OMGlassRules.edgeHighlightStops(recipe)
        surface(content, recipe: recipe)
            .overlay {
                if let border = recipe.border {
                    shape.strokeBorder(border.color, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if !stops.isEmpty {
                    shape.strokeBorder(
                        LinearGradient(
                            stops: stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) },
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func surface(_ content: Content, recipe: OMGlassRecipe) -> some View {
        if OMGlassRules.usesSystemGlass(kind) {
            content.glassEffect(.regular.tint(recipe.fill.color), in: shape)
        } else {
            content.background {
                shape.fill(recipe.fill.color)
                    .shadow(
                        color: recipe.shadow?.color.color ?? .clear,
                        radius: OMGlassRules.shadowRadius(cssBlur: recipe.shadow?.blur ?? 0),
                        x: 0,
                        y: recipe.shadow?.y ?? 0
                    )
            }
        }
    }
}

// MARK: - Sidebar pill (spec § Components, "Sidebar")

/// What one sidebar item wears.
struct OMSidebarPillAppearance: Equatable {
    let showsPill: Bool
    let title: OMColorToken
    let icon: OMColorToken
    let weight: Font.Weight
}

/// The sidebar item from `Dashboard-Overview(-Light).dc.html`: the selected item is
/// a raised pill with an accent icon and a semibold title; the others are bare, in
/// secondary, medium weight.
enum OMSidebarPillRules {
    static let height: CGFloat = 34
    static let horizontalPadding: CGFloat = 12
    static let iconSpacing: CGFloat = 10
    static let fontSize: CGFloat = 13

    static func appearance(isSelected: Bool) -> OMSidebarPillAppearance {
        isSelected
            ? OMSidebarPillAppearance(showsPill: true, title: .text, icon: .accentText, weight: .semibold)
            : OMSidebarPillAppearance(showsPill: false, title: .secondary, icon: .secondary, weight: .medium)
    }
}

/// A sidebar item: `Button { … } label: { Label("Overview", systemImage: "square.grid.2x2") }`
/// `.buttonStyle(.omSidebarPill(isSelected: selection == .overview))`.
struct OMSidebarPillButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let look = OMSidebarPillRules.appearance(isSelected: isSelected)
        configuration.label
            .foregroundStyle(.om(look.title))
            .labelStyle(OMSidebarPillLabelStyle(appearance: look))
            .font(.system(size: OMSidebarPillRules.fontSize, weight: look.weight))
            .padding(.horizontal, OMSidebarPillRules.horizontalPadding)
            .frame(height: OMSidebarPillRules.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(OMCornerShape(.navItem))
            .modifier(OMSidebarPillBackground(showsPill: look.showsPill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension ButtonStyle where Self == OMSidebarPillButtonStyle {
    static func omSidebarPill(isSelected: Bool) -> OMSidebarPillButtonStyle {
        OMSidebarPillButtonStyle(isSelected: isSelected)
    }
}

/// Icon and title coloured separately: the selected icon takes the accent.
private struct OMSidebarPillLabelStyle: LabelStyle {
    let appearance: OMSidebarPillAppearance

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: OMSidebarPillRules.iconSpacing) {
            configuration.icon
                .foregroundStyle(.om(appearance.icon))
            configuration.title
                .foregroundStyle(.om(appearance.title))
        }
    }
}

private struct OMSidebarPillBackground: ViewModifier {
    let showsPill: Bool

    func body(content: Content) -> some View {
        if showsPill {
            content.raisedPill(in: OMCornerShape(.navItem))
        } else {
            content
        }
    }
}

// MARK: - Link (spec § Components, "Links")

/// A summary's way to the screen that owns the detail: accent text and a chevron,
/// no button chrome ("History ›", "Show all 103"). Values from
/// `Dashboard-Overview(-Light).dc.html`.
enum OMLinkRules {
    static let textToken: OMColorToken = .accentText
    static let chevronSymbol = "chevron.right"
    static let spacing: CGFloat = 2
    static let fontSize: CGFloat = 12.5
    /// The mockups' 12 pt chevron box draws a glyph about 6 pt tall; SF Symbols' bold
    /// chevron at 9 pt matches it.
    static let chevronSize: CGFloat = 9
}

/// `Button("History") { … }.buttonStyle(.omLink)`.
struct OMLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: OMLinkRules.spacing) {
            configuration.label
            Image(systemName: OMLinkRules.chevronSymbol)
                .font(.system(size: OMLinkRules.chevronSize, weight: .bold))
                .accessibilityHidden(true)
        }
        .font(.system(size: OMLinkRules.fontSize, weight: .semibold))
        .foregroundStyle(.om(OMLinkRules.textToken))
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == OMLinkButtonStyle {
    static var omLink: OMLinkButtonStyle { OMLinkButtonStyle() }
}
