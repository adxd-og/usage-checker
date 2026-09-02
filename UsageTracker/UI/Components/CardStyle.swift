import SwiftUI

extension View {
    /// System-Settings-style inset card: continuous corners, quiet system fill,
    /// hairline separator stroke. One look for every dashboard card, and the same
    /// surface tokens the popover's tiles use.
    func dashboardCard(padding: CGFloat = OMSpacing.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                    .fill(OMSurface.tile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                    .strokeBorder(OMSurface.hairline, lineWidth: 0.5)
            )
    }
}
