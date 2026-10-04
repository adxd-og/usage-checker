import Foundation

/// The words for a prepaid credit pool's dollars (cloud session credits spec): used over
/// limit in whole dollars, `$231 / $250`. In `CLICore`, compiled into the app and the
/// `omelette` tool both, so the popover's row and the terminal print the same figures.
enum CreditCopy {
    /// `$231 / $250`. Used is rounded to the dollar: the pool is spent in fractions of a
    /// cent, and claude.ai itself shows it in whole dollars ("$19 of $250 left").
    static func value(usedDollars: Double, limitDollars: Double, locale: Locale = .current) -> String {
        "\(dollars(usedDollars, locale: locale)) / \(dollars(limitDollars, locale: locale))"
    }

    /// Whole dollars in `locale`'s currency spelling: the extra-usage row formats its
    /// limit the same way (`.currency(code: "USD").precision(.fractionLength(0))`).
    static func dollars(_ amount: Double, locale: Locale = .current) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(locale))
    }

    /// The terminal spells every dollar `$`: `StatusText.costParts` prints `$%.2f`
    /// whatever the machine's locale, so a credit pool's figures there match it.
    static let terminalLocale = Locale(identifier: "en_US")

    /// `$231 used of $250, expires 5 Nov, 7:59`: what `omelette status` and the MCP
    /// paragraph print after a credit pool's label, the popover row's figures and
    /// tooltip on one line. In words rather than the row's `/`: with no bar beside it,
    /// a reader — or a model reading `get_usage` — could take $231 for what is left,
    /// where claude.ai says "$19 of $250 left". nil for a window that is not a credit
    /// pool.
    static func terminalFigures(
        _ window: StatusSnapshot.Window, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        guard let limit = window.limitDollars else { return nil }
        let used = dollars(window.usedDollars ?? 0, locale: terminalLocale)
        let figures = "\(used) used of \(dollars(limit, locale: terminalLocale))"
        guard let at = window.resetsAt,
              let expiry = ResetCopy.absolute(resetsAt: at, now: now, calendar: calendar, locale: locale)
        else { return figures }
        return "\(figures), expires \(expiry)"
    }
}
