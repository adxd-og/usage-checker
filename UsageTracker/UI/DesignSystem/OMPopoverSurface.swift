import SwiftUI

/// The popover's content surfaces (`Main.dc.html`, `Popover-All-Light.dc.html`): a
/// quiet fill with a 1 pt edge on the chrome glass, never glass themselves (spec §
/// Principles 1). Provider tiles are 18 pt; groups — the cost tile, weekly limits,
/// agents, the hooks prompt — are 16 pt. Each caller pads its own content. On the notch
/// island the same surfaces are nearly transparent with a hairline edge (`style(onIsland:)`).
enum OMPopoverSurface: Sendable {
    case tile, group

    var corner: OMCornerContext {
        switch self {
        case .tile: .popoverTile
        case .group: .popoverGroup
        }
    }

    static let fill: OMColorToken = .groupFill
    static let border: OMColorToken = .groupBorder
    static let borderWidth: CGFloat = 1

    /// A surface's fill or edge: a token that follows the colour scheme, or one fixed colour.
    enum Paint: Equatable, Sendable {
        case token(OMColorToken)
        case fixed(OMRGBA)
    }

    struct Style: Equatable, Sendable {
        let fill: Paint
        let border: Paint
        let borderWidth: CGFloat
    }

    /// On the island, which is always dark, tiles and cards are white 5 % with a 0.5 pt
    /// white 11 % hairline, so the island reads as one surface with marks on it (notch-island
    /// spec 2026-10-29 § 3.1, Surfaces on the island; owner 2026-10-30). Everywhere else (the
    /// panel, the Dashboard) the group fill and its 1 pt edge.
    static func style(onIsland: Bool) -> Style {
        onIsland
            ? Style(fill: .fixed(.white(0.05)), border: .fixed(.white(0.11)), borderWidth: 0.5)
            : Style(fill: .token(fill), border: .token(border), borderWidth: borderWidth)
    }
}

extension OMPopoverSurface.Paint: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        switch self {
        case .token(let token): OMPalette.rgba(token, scheme: environment.colorScheme).color
        case .fixed(let rgba): rgba.color
        }
    }
}

extension EnvironmentValues {
    /// Set by the island's root on the island only (`IslandSurfaceRules.surfacesOnIsland`);
    /// false everywhere else, so the panel and the Dashboard keep their surfaces.
    @Entry var popoverSurfaceOnIsland = false
}

extension View {
    /// A popover tile or group: its fill in its corner, edged inside (`OMPopoverSurface.style`).
    func popoverSurface(_ surface: OMPopoverSurface) -> some View {
        modifier(PopoverSurfaceModifier(surface: surface))
    }
}

private struct PopoverSurfaceModifier: ViewModifier {
    let surface: OMPopoverSurface
    @Environment(\.popoverSurfaceOnIsland) private var onIsland

    func body(content: Content) -> some View {
        let style = OMPopoverSurface.style(onIsland: onIsland)
        content
            .background {
                OMCornerShape(surface.corner).fill(style.fill)
            }
            .overlay {
                OMCornerShape(surface.corner)
                    .strokeBorder(style.border, lineWidth: style.borderWidth)
                    .allowsHitTesting(false)
            }
    }
}
