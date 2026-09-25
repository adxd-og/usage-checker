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
}
