import CoreGraphics

/// The controls in the strip beside the camera (notch-island spec 2026-10-29 § 3.4): "‹ All" and the
/// provider logos. Spec 2026-11-03 hangs the island from an external display's menu bar (30 pt measured, 24 pt on some), so a
/// control takes its own height where the row has room for it with `rowInset` above and below, and
/// shrinks to fit where it has not, never below a logo's glyph. Pure.
enum IslandStripRules {
    /// The room a control leaves above and below itself in its row.
    static let rowInset: CGFloat = 1
    /// The least a control shrinks to: a provider logo's glyph.
    static let minimumHeight: CGFloat = 16

    /// A control `native` tall in a row `rowHeight` tall.
    static func controlHeight(native: CGFloat, rowHeight: CGFloat) -> CGFloat {
        min(native, max(minimumHeight, rowHeight - 2 * rowInset))
    }
}
