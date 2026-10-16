import Foundation

/// Every string the Limits tab shows: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab and § Accounts without
/// percent windows, in the words of `Dashboard-Limits(-Light).dc.html`. Each `extension`
/// below is one part of the page.
///
/// A share is percent points of a limit window, a budget, a period's spend or a spend
/// limit. Dollars are US-grouped after a "$" whatever the Mac's region, as History's
/// (`HistoryCopy.numberLocale`).
enum LimitsCopy {}

// MARK: - Figures

extension LimitsCopy {
    /// Shares under this many points read "< 0.1 %" (§ The tab, item 3).
    static let shareFloor: Double = 0.1

    /// "≈ 4.2 %": a chat's, a project's or Outside's points, to one decimal. Under a
    /// tenth of a point it reads "< 0.1 %", a chat whose half hours moved nothing
    /// included: with whole-number percents its quota shows in a later step.
    static func share(_ points: Double) -> String {
        guard points + LimitShareRules.pointSlack >= shareFloor else { return "< 0.1 %" }
        return String(format: "≈ %.1f %%", points)
    }

    /// "≈ 2 %": Outside this Mac on a Claude subscription. It takes whole half hours of
    /// whole-number percents, so it is whole points (§ The tab, item 2).
    static func wholeShare(_ points: Double) -> String {
        "≈ \(Int(points.rounded())) %"
    }

    /// "$1,358", "$62", "$6.20": whole dollars from $10, as the mockup prints them; cents
    /// below, where a whole dollar would hide the figure.
    static func dollars(_ amount: Double) -> String {
        let digits = abs(amount) >= 10 ? 0 : 2
        return amount.formatted(
            .currency(code: "USD").precision(.fractionLength(digits)).locale(HistoryCopy.numberLocale)
        )
    }

    /// "130 M", "9.5 M", "2.5 B", "84 k": a token count and its unit, whole from ten of a
    /// unit, one decimal below.
    static func tokens(_ count: Double) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            String(format: value >= 10 ? "%.0f" : "%.1f", value) + " " + unit
        }
        if count >= 1_000_000_000 { return scaled(count / 1_000_000_000, "B") }
        if count >= 1_000_000 { return scaled(count / 1_000_000, "M") }
        if count >= 1_000 { return scaled(count / 1_000, "k") }
        return String(format: "%.0f", count)
    }
}

// MARK: - A page without cards

extension LimitsCopy {
    static let unsupported = "Limit analytics needs a chat-level cost log. Claude and Codex have one."
    static let loading = "Loading…"
    static let noSpend = "Nothing spent in the last 7 days."

    /// An account that reports no window, budget or spend limit: signed out, or not
    /// polled yet.
    static func nothingToMeasure(providerName: String) -> String {
        "\(providerName) has reported no limit to measure yet."
    }

    /// A subscription whose window has no reset time yet: it opens with the next message.
    static func noOpenWindow(_ span: LimitsSpan) -> String {
        switch span {
        case .session: return "No session window is open right now."
        case .week: return "No weekly window is open right now."
        case .month: return "No monthly window is open right now."
        }
    }

    /// The sentence a page shows in place of its cards; nil for the page with cards.
    static func message(for page: LimitsPage, providerName: String) -> String? {
        switch page {
        case .unsupported: return unsupported
        case .nothingToMeasure: return nothingToMeasure(providerName: providerName)
        case .noOpenWindow(let span): return noOpenWindow(span)
        case .loading: return loading
        case .noSpend: return noSpend
        case .ready: return nil
        }
    }
}

// MARK: - Window switch

extension LimitsCopy {
    /// What VoiceOver calls the Session / Week switch.
    static let windowPickerLabel = "Limit window"

    /// A segment of the switch: "Session", "Week", or "Month" for Codex Free's 30 days.
    static func windowName(_ span: LimitsSpan) -> String {
        switch span {
        case .session: return "Session"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}
