import SwiftUI

extension View {
    /// System-Settings-style inset card: continuous corners, quiet system fill,
    /// hairline separator stroke. One look for every dashboard card.
    func dashboardCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
    }

}

/// Battery-style status color for a usage percentage: calm while comfortable,
/// amber when high, red when critical. Shared by every gauge in the app.
func usageStatusColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .accentColor
}
