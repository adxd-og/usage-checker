import SwiftUI

/// History's measurements, from `Dashboard-History-*.dc.html` and
/// `Dashboard-Quota-History.dc.html` (liquid-glass spec § Screens, the History rows).
/// Numbers only, and the one width decision the chat list takes; the views read them.
enum HistoryLayout {}

// MARK: - Page

extension HistoryLayout {
    /// The mockups' 20 pt between the title and the controls row, less the 12 pt
    /// `DashboardHeader` leaves under itself.
    static let controlsTopPadding: CGFloat = 8
    /// Between the controls in the row (`gap: 10px`).
    static let controlSpacing: CGFloat = 10
}
