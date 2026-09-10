import Foundation

/// The two dollar amounts behind a spend-limit ring.
///
/// A percentage alone only answers "how much is left" for someone who already
/// knows the limit — and an Enterprise/Team spend limit (or a subscription's
/// prepaid extra credits) is exactly the number people don't hold in their head.
/// The provider tab has printed both amounts all along; this is the same pair for
/// the surfaces that have room for one line: the dashboard hero and the All-tab
/// tile, where the ring's reset slot is empty because a spend limit never resets.
///
/// These are the amounts Anthropic reports for the billing period, in dollars.
enum SpendLimitCopy {
    /// "$431.26 of $1,500" — the used amount to the cent, the limit rounded, both
    /// in the viewer's own number formatting.
    ///
    /// `compact` drops the cents from the used amount too, for the 10 pt line on a
    /// tile: "$431 of $1,500". nil when the account has no extra usage, has it
    /// switched off, or has no limit to measure against — those services keep the
    /// screen they have today.
    nonisolated static func caption(
        _ extra: ExtraUsage?,
        compact: Bool,
        locale: Locale = .current
    ) -> String? {
        guard let extra, extra.isEnabled, extra.monthlyLimit > 0 else { return nil }
        let used = extra.usedCredits.formatted(
            .currency(code: "USD").precision(.fractionLength(compact ? 0 : 2)).locale(locale)
        )
        let limit = extra.monthlyLimit.formatted(
            .currency(code: "USD").precision(.fractionLength(0)).locale(locale)
        )
        return "\(used) of \(limit)"
    }
}
