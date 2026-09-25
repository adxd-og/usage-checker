import SwiftUI

/// The Agents tab's measurements, from `Dashboard-Agents(-Light).dc.html`. The column's
/// side gutters are `DashboardShellLayout.columnLeading` / `columnTrailing`, shared with
/// the header.
enum AgentsLayout {
    // MARK: Title row

    /// Between the source filter and the range picker (`gap: 12px`).
    static let headerControlsSpacing: CGFloat = 12
}
