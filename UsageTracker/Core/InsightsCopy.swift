import Foundation

/// Every string the Insights tab shows (liquid-glass spec § Screens, "Insights"). The
/// words are `Dashboard-Insights(-Light).dc.html`'s.
enum InsightsCopy {
    /// A figure with nothing to say yet.
    static let noValue = "—"

    /// Dollars as the popover prints them ("$2,727.56"), in the viewer's locale. Every
    /// dollar on the tab is an API-list-price figure from a local log; the page's
    /// footnote says so once.
    static func money(_ dollars: Double, locale: Locale = .current) -> String {
        OMCostTile.money(dollars, locale: locale)
    }

    // MARK: - Days at limit

    static let daysAtLimitTitle = "Days at limit, 7 days"

    /// "3 of 7": the mockup's `[n] of 7`.
    static func daysAtLimit(_ days: Int) -> String {
        "\(days) of \(InsightsRules.daysAtLimitSpan)"
    }

    /// The card's value. `noValue` when not one of the seven days has a reading:
    /// "0 of 7" would vouch for a week the app never saw.
    static func daysAtLimitValue(_ days: QuotaDaysAtCapacity) -> String {
        days.observed == 0 ? noValue : daysAtLimit(days.atCapacity)
    }

    /// "days the peak reached 95%", worded from the threshold that decides the count.
    static var daysAtLimitCaption: String {
        String(format: "days the peak reached %.0f%%", QuotaAnalytics.capacityThreshold)
    }
}
