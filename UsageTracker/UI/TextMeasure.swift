import AppKit

/// How wide a line of text sets in the system font (notch-island spec 2026-10-29 § 3.3:
/// the shared bar-label column, the keep-awake card's rows). The rules take widths, so
/// their tests hand in numbers; only views and `KeepAwakeCardLayout.measuredWidths()`
/// measure.
enum TextMeasure {
    /// The width of `text` in the system font at `size` and `weight`, rounded up to a
    /// whole point.
    @MainActor
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}
