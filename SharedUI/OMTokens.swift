import SwiftUI

/// Omelette design tokens. Every surface (popover, floating window, dashboard,
/// settings, onboarding) reads spacing, radii, type roles and colours from here.
enum OMSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

enum OMRadius {
    static let tile: CGFloat = 16
    static let row: CGFloat = 12

    // 3.0 surfaces (liquid-glass spec § Design → Tokens, "Radii").
    static let popover: CGFloat = 24
    static let popoverGroup: CGFloat = 16
    static let popoverTile: CGFloat = 18
    static let dashboardCard: CGFloat = 22
    static let window: CGFloat = 26
    static let sidebar: CGFloat = 18
    static let navItem: CGFloat = 11

    /// The corner a 3.0 surface wears. Controls are capsules at any height.
    static func corner(for context: OMCornerContext) -> OMCorner {
        switch context {
        case .popover: return .rounded(popover)
        case .popoverGroup: return .rounded(popoverGroup)
        case .popoverTile: return .rounded(popoverTile)
        case .dashboardCard: return .rounded(dashboardCard)
        case .window: return .rounded(window)
        case .sidebar: return .rounded(sidebar)
        case .navItem: return .rounded(navItem)
        case .control: return .capsule
        }
    }
}

/// The 3.0 surfaces that own a corner.
enum OMCornerContext: CaseIterable, Sendable {
    case popover, popoverGroup, popoverTile, dashboardCard, window, sidebar, navItem, control
}

/// A continuous rounded rectangle of a fixed radius, or a capsule.
enum OMCorner: Equatable, Sendable {
    case rounded(CGFloat)
    case capsule
}

/// The shape of a 3.0 surface: `OMCornerShape(.dashboardCard)`. Insettable, so a
/// `strokeBorder` stays inside it; an inset shrinks the radius by the same amount,
/// as `RoundedRectangle`'s does. Paths are built directly, never through a view
/// initializer, so the shape stays usable off the main actor.
struct OMCornerShape: InsettableShape {
    let corner: OMCorner
    let insetAmount: CGFloat

    nonisolated init(_ context: OMCornerContext) {
        self.init(corner: OMRadius.corner(for: context), insetAmount: 0)
    }

    private nonisolated init(corner: OMCorner, insetAmount: CGFloat) {
        self.corner = corner
        self.insetAmount = insetAmount
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch corner {
        case .capsule:
            return Path(roundedRect: inner, cornerRadius: min(inner.width, inner.height) / 2, style: .continuous)
        case .rounded(let radius):
            return Path(roundedRect: inner, cornerRadius: max(0, radius - insetAmount), style: .continuous)
        }
    }

    nonisolated func inset(by amount: CGFloat) -> OMCornerShape {
        OMCornerShape(corner: corner, insetAmount: insetAmount + amount)
    }
}

enum OMFont {
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyStrong = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11)
    /// Section labels: apply `.textCase(.uppercase)` and `.tracking(0.6)` at the use site (OMSectionHeader does).
    static let micro = Font.system(size: 10, weight: .semibold)
    /// Dashboard screen titles. The popover's `title` (13 pt) is far too small for a
    /// 920 pt window, and `.title2` is a dynamic role the rest of the kit doesn't use.
    static let screenTitle = Font.system(size: 22, weight: .semibold)
    static let heroNumeral = Font.system(size: 21, weight: .bold, design: .rounded)
    static let numeral = Font.system(size: 13, weight: .bold, design: .rounded)
    static let menuNumeral = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Every 3.0 figure: SF Pro Rounded with tabular digits (spec § Tokens, "Numerals").
    /// The roles above stay proportional until their screens move to 3.0.
    static func numerals(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Content surfaces use quiet system fills; Liquid Glass is reserved for controls
/// so glass is never stacked on the popover's own material.
enum OMSurface {
    static let tile = AnyShapeStyle(.fill.tertiary)
    static let row = AnyShapeStyle(.fill.quaternary)
    static let hairline = AnyShapeStyle(.separator.opacity(0.5))
}

/// Agent states (phase 2 uses them; defined now so no tokens are added later).
enum OMAgentColor {
    static let needsYou = Color.orange
    static let working = Color.blue
    static let done = Color.green
    static let idle = Color.secondary
}

/// Battery-style status colour for a usage percentage: green while comfortable,
/// amber when high, red when critical. Shared by every gauge in the app.
func usageStatusColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .green
}

// MARK: - 3.0 colour roles (liquid-glass spec § Design → Tokens)

/// One colour as sRGB components and an opacity. A plain value, so the token table
/// can be compared in tests and composited for contrast checks without a renderer.
struct OMRGBA: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// `0xF2B544` → sRGB components: the mockups' hex values go in unchanged.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static func white(_ opacity: Double) -> OMRGBA { OMRGBA(red: 1, green: 1, blue: 1, opacity: opacity) }
    static func black(_ opacity: Double) -> OMRGBA { OMRGBA(red: 0, green: 0, blue: 0, opacity: opacity) }

    func withOpacity(_ opacity: Double) -> OMRGBA {
        OMRGBA(red: red, green: green, blue: blue, opacity: opacity)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }

    /// This colour laid over an opaque background, straight alpha in sRGB — how the
    /// mockups' `rgba()` fills composite. The result is opaque.
    func composited(over background: OMRGBA) -> OMRGBA {
        OMRGBA(
            red: red * opacity + background.red * (1 - opacity),
            green: green * opacity + background.green * (1 - opacity),
            blue: blue * opacity + background.blue * (1 - opacity)
        )
    }

    /// WCAG 2 relative luminance of the RGB components (opacity ignored).
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio between two opaque colours, 1…21, in either order.
    static func contrastRatio(_ a: OMRGBA, _ b: OMRGBA) -> Double {
        let lighter = max(a.relativeLuminance, b.relativeLuminance)
        let darker = min(a.relativeLuminance, b.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Every 3.0 colour role. Each has one value per appearance, from
/// `OMPalette.rgba(_:scheme:)`; views use `.om(_:)`.
enum OMColorToken: CaseIterable, Sendable {
    /// Yolk, as a fill: Needs you, Allow, today's bar, heatmap.
    case accent
    /// The accent as text and small glyphs (links, selected nav icon): yolk in dark,
    /// yolk mixed 52 % with the text colour in light, where plain yolk is too faint.
    case accentText
    case text
    /// Captions. Never below 4.5:1 on the window or a card.
    case secondary
    /// Cards and groups; `contentBorder` is their 1 px edge.
    case contentFill
    case contentBorder
    /// Bar and ring tracks.
    case track
    /// Row separators.
    case hairline
    /// Gauges and "On track"; `okText` when it is text.
    case ok
    case okText
    /// The agent working dot and the 3 px halo around it.
    case working
    case workingHalo
    /// Keyboard focus on a ring, a legend row or a control (`OMFocusRing.width` wide).
    case focusRing
    /// Overview rings.
    case seriesSession
    case seriesAllModels
    case seriesPerModel
    /// Token categories in stacked bars and legends.
    case tokenInput
    case tokenOutput
    case tokenCacheRead
    case tokenCacheWrite
    /// The flat colour under the window backdrop's gradients.
    case windowBase
}

/// The 3.0 colour table (spec § Tokens; hex values are the mockups').
enum OMPalette {
    /// The value `token` takes in `scheme`. Anything that is not `.dark` reads the
    /// light table, so an appearance SwiftUI adds later falls back instead of failing.
    static func rgba(_ token: OMColorToken, scheme: ColorScheme) -> OMRGBA {
        let (dark, light) = values(token)
        return scheme == .dark ? dark : light
    }

    private static func values(_ token: OMColorToken) -> (dark: OMRGBA, light: OMRGBA) {
        switch token {
        case .accent: return (OMRGBA(hex: 0xF2B544), OMRGBA(hex: 0xF2B544))
        // color-mix(in oklab, #F2B544 52%, #1D1D1F), computed once.
        case .accentText: return (OMRGBA(hex: 0xF2B544), OMRGBA(hex: 0x846739))
        case .text: return (OMRGBA(hex: 0xF5F5F7), OMRGBA(hex: 0x1D1D1F))
        case .secondary: return (OMRGBA(hex: 0xF5F5F7, opacity: 0.64), OMRGBA(hex: 0x1D1D1F, opacity: 0.64))
        case .contentFill: return (.white(0.055), .white(0.72))
        case .contentBorder: return (.white(0.05), .black(0.05))
        case .track: return (.white(0.10), .black(0.08))
        case .hairline: return (.white(0.07), .black(0.08))
        case .ok: return (OMRGBA(hex: 0x6FD99A), OMRGBA(hex: 0x2FB36A))
        case .okText: return (OMRGBA(hex: 0x7FE3A8), OMRGBA(hex: 0x1E8A4F))
        case .working: return (OMRGBA(hex: 0x6EA8FF), OMRGBA(hex: 0x2F7BF5))
        case .workingHalo: return (OMRGBA(hex: 0x6EA8FF, opacity: 0.25), OMRGBA(hex: 0x2F7BF5, opacity: 0.25))
        case .focusRing: return (OMRGBA(hex: 0xF2B544, opacity: 0.28), OMRGBA(hex: 0xF2B544, opacity: 0.28))
        case .seriesSession: return (OMRGBA(hex: 0x6FD99A), OMRGBA(hex: 0x2FB36A))
        case .seriesAllModels: return (OMRGBA(hex: 0x7AA2FF), OMRGBA(hex: 0x4C7EF3))
        case .seriesPerModel: return (OMRGBA(hex: 0xC79BFF), OMRGBA(hex: 0x9A66EE))
        case .tokenInput: return (OMRGBA(hex: 0x7AA2FF), OMRGBA(hex: 0x4C7EF3))
        case .tokenOutput: return (OMRGBA(hex: 0xF59E6B), OMRGBA(hex: 0xEE7B3A))
        case .tokenCacheRead: return (OMRGBA(hex: 0x5CC8C8), OMRGBA(hex: 0x26A8A8))
        case .tokenCacheWrite: return (OMRGBA(hex: 0xC79BFF), OMRGBA(hex: 0x9A66EE))
        case .windowBase: return (OMRGBA(hex: 0x0D0E13), OMRGBA(hex: 0xECE8F1))
        }
    }
}

/// Keyboard focus: a `focusRing` band this wide just outside the focused shape.
enum OMFocusRing {
    static let width: CGFloat = 3
}

/// A colour token as a `ShapeStyle` that takes its value from the environment's
/// `colorScheme` when SwiftUI draws it: `.foregroundStyle(.om(.secondary))`. Pure
/// SwiftUI, so the widget compiles it too.
struct OMColor: ShapeStyle {
    let token: OMColorToken

    init(_ token: OMColorToken) {
        self.token = token
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        OMPalette.rgba(token, scheme: environment.colorScheme).color
    }
}

extension ShapeStyle where Self == OMColor {
    static func om(_ token: OMColorToken) -> OMColor { OMColor(token) }
}
