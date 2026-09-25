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
    /// The 2.x uppercase label (`.textCase(.uppercase)`, `.tracking(0.6)` at the use site).
    /// 3.0 section titles are sentence case (`OMSectionHeader`).
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

    /// Dashboard screen titles in 3.0: the mockups' `font-size: 26px; font-weight: 700`.
    /// Its own role because `screenTitle` also titles the welcome tour, which 3.0 leaves as it is.
    static let dashboardTitle = Font.system(size: 26, weight: .bold)
    /// The line under a dashboard screen title: the mockups' `font-size: 12.5px`, half a
    /// point over `body`.
    static let dashboardSubtitle = Font.system(size: 12.5)
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

/// The band a gauge is in, decided on the used value: `usageStatusColor`'s three
/// bands (under 70, 70–89, 90 and over) as 3.0 tokens. The 2.x gauges and the widget
/// keep `usageStatusColor`.
enum OMGaugeTone: CaseIterable, Sendable {
    case ok, warning, critical

    static func forUsed(_ percent: Double) -> OMGaugeTone {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .ok
    }

    /// Arcs and bar fills.
    var fill: OMColorToken {
        switch self {
        case .ok: .ok
        case .warning: .warning
        case .critical: .critical
        }
    }

    /// Text in the band's colour ("On track", "Running hot").
    var text: OMColorToken {
        switch self {
        case .ok: .okText
        case .warning: .warning
        case .critical: .critical
        }
    }
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
    /// The dashboard window's body over the backdrop: the mockups' window fill.
    case windowTint
    /// The popover's tiles and groups. Dark matches the content fill; the light
    /// popover draws them at white 55 % with a white 70 % edge (`Popover-All-Light`),
    /// because they sit on its white-56 % chrome glass, not on a window.
    case groupFill
    case groupBorder
    /// A mark that is there but says nothing live: a last-known ring's arc, an idle
    /// agent's dot.
    case muted
    /// The pace dot on a ring and the pace tick on a bar.
    case paceMarker
    /// A label on an accent fill (Allow).
    case onAccent
    /// Gauges and state text at 70–89 % used, and a provider that wants signing in.
    /// The spec's table has no amber: this is the system orange the 2.x gauges draw.
    case warning
    /// Gauges and state text at 90 % used and over, and a provider in error: the
    /// system red.
    case critical
    /// The Overview CLI card's bars for the seven days "Last 7 days" counts: the track at
    /// twice its strength (`Dashboard-Overview(-Light).dc.html`).
    case barRecent
    /// The quota chart's one line colour no other series has (`Dashboard-Quota-History`).
    case seriesQuota
    /// A heatmap square for a day with nothing on it (`Dashboard-History-Calendar`).
    case calendarEmpty
    /// The chart tooltip's opaque bubble and its edge (`Dashboard-History-Cost`).
    case tooltipFill
    case tooltipBorder
    /// The wash under an open chat in History (`Dashboard-History-Chats`).
    case insetFill
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
        case .windowTint: return (OMRGBA(hex: 0x14151A, opacity: 0.9), OMRGBA(hex: 0xF7F6FA, opacity: 0.86))
        case .groupFill: return (.white(0.055), .white(0.55))
        case .groupBorder: return (.white(0.05), .white(0.70))
        case .muted: return (OMRGBA(hex: 0xF5F5F7, opacity: 0.40), OMRGBA(hex: 0x1D1D1F, opacity: 0.35))
        case .paceMarker: return (.white(0.75), OMRGBA(hex: 0x1D1D1F, opacity: 0.60))
        case .onAccent: return (OMRGBA(hex: 0x231704), OMRGBA(hex: 0x231704))
        case .warning: return (OMRGBA(hex: 0xFF9F0A), OMRGBA(hex: 0xFF9500))
        case .critical: return (OMRGBA(hex: 0xFF453A), OMRGBA(hex: 0xFF3B30))
        case .barRecent: return (.white(0.20), .black(0.16))
        case .seriesQuota: return (OMRGBA(hex: 0xFF7A7A), OMRGBA(hex: 0xE85555))
        case .calendarEmpty: return (.white(0.06), .black(0.06))
        case .tooltipFill: return (OMRGBA(hex: 0x2A2B31), OMRGBA(hex: 0xFFFFFF))
        case .tooltipBorder: return (.white(0.12), .black(0.10))
        case .insetFill: return (.white(0.035), .black(0.025))
        }
    }
}

/// Keyboard focus: a `focusRing` band this wide just outside the focused shape.
enum OMFocusRing {
    static let width: CGFloat = 3

    /// The macOS convention: the ring shows only while the user navigates with the
    /// keyboard. Focus a click gave or left behind draws nothing.
    static func isVisible(isFocused: Bool, keyboardNavigation: Bool) -> Bool {
        isFocused && keyboardNavigation
    }

    /// Keys that move focus or selection through a control; pressing one inside it
    /// turns keyboard navigation on. Computed: `KeyEquivalent` is not a stored static.
    static var navigationKeys: Set<KeyEquivalent> {
        [.tab, .leftArrow, .rightArrow, .upArrow, .downArrow]
    }

    /// Whether keyboard navigation holds after focus moved: Tab into a control from
    /// outside reaches it only as its focus arriving, so a key press that moved focus in
    /// counts; a click that moved it, or focus leaving, does not.
    static func keyboardNavigation(afterFocusMovedTo isFocused: Bool, byKeyPress: Bool) -> Bool {
        isFocused && byKeyPress
    }
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

// MARK: - 3.0 window backdrop (spec § Tokens, "window background")

/// One soft colour pool of the window backdrop: the mockups' CSS
/// `radial-gradient(<radiusX> <radiusY> at <x> <y>, <color>, transparent <fadeStop>)`.
/// `x` and `y` are fractions of the window; the radii are points, as the CSS writes them.
struct OMBackdropPool: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let radiusX: CGFloat
    let radiusY: CGFloat
    let color: OMRGBA
    /// Fraction of the radius where the colour has faded to transparent.
    let fadeStop: CGFloat
}

/// A flat base and the colour pools over it.
struct OMWindowBackdrop: Equatable, Sendable {
    let base: OMRGBA
    /// In CSS declaration order: the first pool is the top layer.
    let pools: [OMBackdropPool]

    /// The pools in the order to paint them, bottom first and topmost last. CSS draws
    /// its first background layer on top, so this is `pools` reversed.
    var paintOrder: [OMBackdropPool] { pools.reversed() }
}

extension OMPalette {
    /// `Main.dc.html`'s backdrop in dark, `Popover-All-Light.dc.html`'s in light.
    static func windowBackdrop(scheme: ColorScheme) -> OMWindowBackdrop {
        let base = rgba(.windowBase, scheme: scheme)
        if scheme == .dark {
            return OMWindowBackdrop(base: base, pools: [
                OMBackdropPool(x: 0.12, y: 0.08, radiusX: 560, radiusY: 420, color: OMRGBA(hex: 0xF2B544, opacity: 0.55), fadeStop: 0.62),
                OMBackdropPool(x: 0.92, y: 0.62, radiusX: 560, radiusY: 520, color: OMRGBA(hex: 0x5C70FF, opacity: 0.5), fadeStop: 0.64),
                OMBackdropPool(x: 0.60, y: 1.00, radiusX: 420, radiusY: 320, color: OMRGBA(hex: 0xFF6E78, opacity: 0.3), fadeStop: 0.62),
            ])
        }
        return OMWindowBackdrop(base: base, pools: [
            OMBackdropPool(x: 0.10, y: 0.06, radiusX: 560, radiusY: 420, color: OMRGBA(hex: 0xFFC478, opacity: 0.75), fadeStop: 0.62),
            OMBackdropPool(x: 0.94, y: 0.60, radiusX: 560, radiusY: 520, color: OMRGBA(hex: 0x8CAAFF, opacity: 0.7), fadeStop: 0.64),
            OMBackdropPool(x: 0.55, y: 1.00, radiusX: 420, radiusY: 320, color: OMRGBA(hex: 0xFFA0B4, opacity: 0.5), fadeStop: 0.62),
        ])
    }
}

// MARK: - 3.0 glass recipes (spec § Tokens: chrome glass, pane glass, raised pill)

/// The four glass surfaces of 3.0.
enum OMGlassKind: CaseIterable, Sendable {
    /// Popover body, window chrome and the dashboard and Settings sidebars.
    case chrome
    /// Glass over the content fill: the dashboard cards.
    case pane
    /// The capsule track under a segmented control. The spec files it under chrome
    /// glass; the mockups draw it on the chrome body as a faint overlay, so it has its
    /// own values rather than a second chrome layer.
    case controlTrack
    /// The selected segment or nav item, raised on its control track or on the sidebar's chrome glass.
    case raisedPill
    /// The dashboard sidebar: chrome glass whose light edge is the hairline, not the
    /// popover body's white rim.
    case sidebar
}

/// A CSS `box-shadow: 0 <y> <blur> <color>` from the mockups.
struct OMShadow: Equatable, Sendable {
    let color: OMRGBA
    let y: CGFloat
    let blur: CGFloat
}

/// What one glass surface wears in one appearance. `fill` tints the system glass
/// (for the raised pill it is the pill's own fill); `border` is 1 px inside the
/// shape; the highlights are 1 px inner edge lights at the top and the bottom.
struct OMGlassRecipe: Equatable, Sendable {
    let fill: OMRGBA
    let border: OMRGBA?
    let topHighlight: OMRGBA?
    let bottomHighlight: OMRGBA?
    let shadow: OMShadow?
}

/// The glass table. The mockups' `backdrop-filter` values are the target look, not
/// the implementation: the blur is the system's, and these numbers tint and edge it
/// until the owner's visual check matches the screens (spec § Platform floor).
enum OMGlass {
    static func recipe(_ kind: OMGlassKind, scheme: ColorScheme) -> OMGlassRecipe {
        let dark = scheme == .dark
        switch kind {
        case .chrome:
            return dark
                ? OMGlassRecipe(fill: OMRGBA(hex: 0x1A1A1F, opacity: 0.6), border: .white(0.11),
                                topHighlight: .white(0.16), bottomHighlight: .white(0.03), shadow: nil)
                : OMGlassRecipe(fill: .white(0.56), border: .white(0.75),
                                topHighlight: .white(0.95), bottomHighlight: nil, shadow: nil)
        case .pane:
            return OMGlassRecipe(fill: OMPalette.rgba(.contentFill, scheme: scheme),
                                 border: OMPalette.rgba(.contentBorder, scheme: scheme),
                                 topHighlight: nil, bottomHighlight: nil, shadow: nil)
        case .controlTrack:
            return dark
                ? OMGlassRecipe(fill: .white(0.07), border: .white(0.08),
                                topHighlight: .white(0.08), bottomHighlight: nil, shadow: nil)
                : OMGlassRecipe(fill: .black(0.05), border: .white(0.6),
                                topHighlight: .white(0.6), bottomHighlight: nil, shadow: nil)
        case .raisedPill:
            return dark
                ? OMGlassRecipe(fill: .white(0.17), border: nil, topHighlight: .white(0.28), bottomHighlight: nil,
                                shadow: OMShadow(color: .black(0.35), y: 1, blur: 4))
                : OMGlassRecipe(fill: .white(0.95), border: nil, topHighlight: .white(1), bottomHighlight: nil,
                                shadow: OMShadow(color: OMRGBA(hex: 0x281E50, opacity: 0.16), y: 1, blur: 4))
        case .sidebar:
            // Chrome, with the hairline as its light edge: the dashboard mockups' dark
            // rgba(29,29,31,0.6) outline is a design-file artefact (session ruling,
            // 2026-09-25). Dark keeps chrome's white edge, as the mockups draw it.
            let chrome = recipe(.chrome, scheme: scheme)
            guard !dark else { return chrome }
            return OMGlassRecipe(fill: chrome.fill, border: OMPalette.rgba(.hairline, scheme: .light),
                                 topHighlight: chrome.topHighlight, bottomHighlight: chrome.bottomHighlight,
                                 shadow: chrome.shadow)
        }
    }

    /// The dashboard sidebar's drop shadows, in the mockups' CSS order (the `<nav>` of
    /// `Dashboard-Overview(-Light).dc.html`). System glass draws no recipe shadow, so the
    /// sidebar casts these itself.
    static func sidebarShadows(scheme: ColorScheme) -> [OMShadow] {
        scheme == .dark
            ? [OMShadow(color: .black(0.35), y: 10, blur: 30), OMShadow(color: .black(0.3), y: 2, blur: 10)]
            : [OMShadow(color: OMRGBA(hex: 0x32285A, opacity: 0.1), y: 8, blur: 24),
               OMShadow(color: OMRGBA(hex: 0x32285A, opacity: 0.08), y: 2, blur: 8)]
    }
}
