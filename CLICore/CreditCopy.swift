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
}
