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

    /// `$231 / $250, expires 5 Nov, 7:59`: what `omelette status` and the MCP paragraph
    /// print after a credit pool's label, the popover row's value and tooltip on one
    /// line. nil for a window that is not a credit pool.
    static func terminalFigures(
        _ window: StatusSnapshot.Window, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        guard let limit = window.limitDollars else { return nil }
        let figures = value(usedDollars: window.usedDollars ?? 0, limitDollars: limit, locale: terminalLocale)
        guard let at = window.resetsAt,
              let expiry = ResetCopy.absolute(resetsAt: at, now: now, calendar: calendar, locale: locale)
        else { return figures }
        return "\(figures), expires \(expiry)"
    }
}
