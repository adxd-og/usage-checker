import SwiftUI

/// The dashboard window around its two columns (liquid-glass spec § Components,
/// "Sidebar"; `Dashboard-Overview(-Light).dc.html`, a 1280 × 840 window with 10 pt of
/// padding). The sidebar floats `windowInset` inside the window's left, top and bottom
/// edges; the detail column keeps the same margin on its top, bottom and right.
enum DashboardShellLayout {
    static let windowInset: CGFloat = 10
    /// The mockups' window: the size a first open gets.
    static let idealWidth: CGFloat = 1280
    static let idealHeight: CGFloat = 840
    /// 2.7's narrowest detail column: its 820 pt floor with the sidebar at the 180 pt
    /// default. The wider 3.0 sidebar raises the window's floor, not the column's.
    static let minimumDetailWidth: CGFloat = 640
    static let minWidth: CGFloat = windowInset + DashboardSidebarRules.width + minimumDetailWidth + windowInset
    /// The detail column's padding in every dashboard mockup (`24px 32px 32px 30px`).
    /// The header sits on it now; each tab's body moves onto it in its own package
    /// (P3–P6), since they cannot all edit the shared header.
    static let columnTop: CGFloat = 24
    static let columnLeading: CGFloat = 30
    static let columnTrailing: CGFloat = 32
    /// Unchanged from 2.7: the mockups set no floor.
    static let minHeight: CGFloat = 560

    /// The traffic lights sit inside the sidebar panel, this far from its top and left
    /// edges (the mockups' `<nav>` padding: 16 pt on top, 10 + 6 pt on the left).
    static let windowButtonsPadding: CGFloat = 16

    /// Where the close button goes, as an AppKit frame origin in the content view's
    /// bottom-left coordinates: `windowButtonsPadding` inside the sidebar's top-left
    /// corner, which is `windowInset` inside the window's. The other two buttons keep
    /// their system offsets from it.
    nonisolated static func windowButtonsOrigin(closeButtonSize: CGSize, contentHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: windowInset + windowButtonsPadding,
            y: contentHeight - windowInset - windowButtonsPadding - closeButtonSize.height
        )
    }

    /// How far the title-bar strip must reach down from the window's top edge to hold
    /// the moved buttons whole. AppKit's strip is shorter, and a click on the part of a
    /// button outside it falls through to the content.
    nonisolated static func windowButtonsStripHeight(closeButtonSize: CGSize) -> CGFloat {
        windowInset + windowButtonsPadding + closeButtonSize.height
    }
}
