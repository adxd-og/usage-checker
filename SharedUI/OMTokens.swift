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
