import SwiftUI

/// The 3.0 dashboard card (liquid-glass spec § Tokens, "pane glass" and radius 22):
/// `Dashboard-Overview(-Light).dc.html` draws every card in the content fill with a 1 px
/// border, over glass. Every tab's cards wear it.
enum DashboardCardRules {
    static let surface: OMGlassKind = .pane
    static let corner: OMCornerContext = .dashboardCard
}

extension View {
    /// One look for every dashboard card: pane glass in the dashboard-card corner.
    func dashboardCard(padding: CGFloat = OMSpacing.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .omGlass(DashboardCardRules.surface, in: OMCornerShape(DashboardCardRules.corner))
    }
}
