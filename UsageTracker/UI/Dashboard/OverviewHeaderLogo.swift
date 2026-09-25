import SwiftUI

/// Which provider's logo the Overview header's tile draws.
struct OverviewHeaderLogo: Equatable, Sendable {
    let serviceID: String
    /// The symbol `ProviderIconView` draws only when no bundled logo matches the id.
    let sfFallback: String
}

/// The logo tile left of the Overview title (liquid-glass spec § Screens, "Overview";
/// `Dashboard-Overview(-Light).dc.html`, the header's `width: 40px; height: 40px;
/// border-radius: 13px` box). The mockup fills it with a brand colour behind a letter,
/// the placeholder every mockup logo box uses; the app draws the provider's own logo in
/// the text colour, as the popover tiles and Settings rows do, on the pane glass of the
/// cards below it.
enum OverviewHeaderRules {
    static let tileSize: CGFloat = 40
    static let tileRadius: CGFloat = 13
    /// The tile less 8 pt a side, so the logo reads as a mark on a tile.
    static let iconSize: CGFloat = 24
    static let surface: OMGlassKind = .pane

    /// The selected provider's tile. A provider on the row only through its recorded
    /// history has no snapshot to name its symbol, so it takes the provider row's
    /// fallback; its bundled logo is found by id either way. nil without a provider.
    static func logo(serviceID: String, service: ServiceSnapshot?) -> OverviewHeaderLogo? {
        guard !serviceID.isEmpty else { return nil }
        return OverviewHeaderLogo(serviceID: serviceID, sfFallback: service?.icon ?? "sparkles")
    }
}

/// The tile itself; decorative, since the title beside it names the provider.
struct OverviewHeaderLogoTile: View {
    let logo: OverviewHeaderLogo

    var body: some View {
        ProviderIconView(serviceID: logo.serviceID, sfFallback: logo.sfFallback, size: OverviewHeaderRules.iconSize)
            .foregroundStyle(.om(.text))
            .frame(width: OverviewHeaderRules.tileSize, height: OverviewHeaderRules.tileSize)
            .omGlass(
                OverviewHeaderRules.surface,
                in: RoundedRectangle(cornerRadius: OverviewHeaderRules.tileRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
