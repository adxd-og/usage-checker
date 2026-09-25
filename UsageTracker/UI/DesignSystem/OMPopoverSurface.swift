import SwiftUI

/// The popover's content surfaces (`Main.dc.html`, `Popover-All-Light.dc.html`): a
/// quiet fill with a 1 pt edge on the chrome glass, never glass themselves (spec §
/// Principles 1). Provider tiles are 18 pt; groups — the cost tile, weekly limits,
/// agents, the hooks prompt — are 16 pt. Each caller pads its own content.
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
}

extension View {
    /// A popover tile or group: the group fill in its corner, edged inside by 1 pt.
    func popoverSurface(_ surface: OMPopoverSurface) -> some View {
        background {
            OMCornerShape(surface.corner).fill(.om(OMPopoverSurface.fill))
        }
        .overlay {
            OMCornerShape(surface.corner)
                .strokeBorder(.om(OMPopoverSurface.border), lineWidth: OMPopoverSurface.borderWidth)
                .allowsHitTesting(false)
        }
    }
}
