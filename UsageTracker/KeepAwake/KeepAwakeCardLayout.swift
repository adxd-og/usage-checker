import AppKit

/// How the keep-awake card lays out its controls in one half of the island's grid
/// (notch-island spec 2026-10-29 § 3.3, Keep-awake card; § 3.9 `KeepAwakeCardLayout`;
/// review finding 6). Behaviour is the keep-awake spec's, unchanged: typed days, hours and
/// minutes, Apply, Cancel while armed. Under the one-row width the fields take one row and
/// Apply, Cancel and the spinner the next; notices wrap below. Pure: the widths come in.
enum KeepAwakeCardLayout {
    enum Arrangement: Equatable, Sendable {
        /// The fields, then the buttons, on one row.
        case oneRow
        /// The fields on one row; Apply, Cancel and the spinner on the next.
        case twoRows
    }

    /// What the controls measure, in points.
    struct Widths: Equatable, Sendable {
        /// The unit after each field, in order: d, h, min.
        let units: [CGFloat]
        /// The Apply capsule.
        let apply: CGFloat
        /// The Cancel capsule, shown while armed.
        let cancel: CGFloat
        /// The small spinner while a request runs.
        let spinner: CGFloat
        /// Open Login Items, the approval state's button, on its own line.
        let approval: CGFloat
    }

    /// Two digits fit; three 44 pt fields with their units did not fit a 192 pt card.
    static let fieldWidth: CGFloat = 38
    /// Between a field and its unit.
    static let unitSpacing: CGFloat = 3
    /// Between the fields, between the buttons, and between the two groups on one row.
    static let spacing: CGFloat = 8
    /// The card's padding (§ 3.3 tokens).
    static let padding: CGFloat = 14
    /// The least space between the status above and the controls pinned to the bottom.
    static let controlsGap: CGFloat = 12
    /// A small `ProgressView`.
    static let spinnerWidth: CGFloat = 16

    /// The three fields with their units.
    static func fieldsWidth(_ widths: Widths) -> CGFloat {
        let count = CGFloat(widths.units.count)
        return count * (fieldWidth + unitSpacing) + widths.units.reduce(0, +) + max(0, count - 1) * spacing
    }

    /// Apply, Cancel and the spinner at once: the widest the buttons get (armed and
    /// working).
    static func buttonsWidth(_ widths: Widths) -> CGFloat {
        widths.apply + spacing + widths.cancel + spacing + widths.spinner
    }

    static func oneRowWidth(_ widths: Widths) -> CGFloat {
        fieldsWidth(widths) + spacing + buttonsWidth(widths)
    }

    static func arrangement(interiorWidth: CGFloat, widths: Widths) -> Arrangement {
        interiorWidth >= oneRowWidth(widths) ? .oneRow : .twoRows
    }

    /// Whether every line the card can draw fits `interiorWidth`: the fields, the buttons,
    /// the approval button. A test-time check with measured widths; the card itself does
    /// not fall back if a line is wider at run time.
    static func linesFit(interiorWidth: CGFloat, widths: Widths) -> Bool {
        max(fieldsWidth(widths), buttonsWidth(widths), widths.approval) <= interiorWidth
    }

    /// The card's own height before the grid stretches it: padding, the status block, the
    /// gap, the controls, padding.
    static func naturalHeight(top: CGFloat, controls: CGFloat) -> CGFloat {
        2 * padding + top + controlsGap + controls
    }

    /// The widths as this Mac's system font sets the controls' words: the units at the
    /// fields' 12.5 pt, the buttons in the capsule's semibold plus its padding.
    @MainActor
    static func measuredWidths() -> Widths {
        let capsule = OMButtonRules.leadingPadding(.small, accent: false) + OMButtonRules.trailingPadding(.small, accent: false)
        func button(_ title: String) -> CGFloat {
            TextMeasure.width(title, size: OMButtonRules.fontSize, weight: .semibold) + capsule
        }
        return Widths(
            units: KeepAwakeCopy.DurationUnit.allCases.map { TextMeasure.width($0.symbol, size: OMKeyValueRow.captionSize) },
            apply: button(KeepAwakeCopy.applyButton),
            cancel: button(KeepAwakeCopy.cancelButton),
            spinner: spinnerWidth,
            approval: button(KeepAwakeCopy.openLoginItemsButton)
        )
    }
}
