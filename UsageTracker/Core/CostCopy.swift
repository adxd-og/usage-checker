import Foundation

/// The words that keep Omelette's dollar figures honest.
///
/// Every dollar figure in this app is computed from the CLIs' own local logs at
/// models.dev list prices. On a subscription that number is what the same tokens
/// *would* cost through the API — it is not the subscription's bill, and people who
/// read it as one either panic or stop trusting the app. One sentence, said once per
/// surface, is the whole fix.
enum CostCopy {
    /// Windows Omelette invents from a budget the user typed into Settings, rather
    /// than ones a provider reported. They must not make a pay-as-you-go account
    /// look like a subscription — see `AppState.applyPayAsYouGo`, which is what
    /// creates this bucket.
    static let syntheticBucketIDs: Set<String> = ["claude_weekly_budget"]

    static let apiEquivalent = "API-equivalent cost of your CLI usage — not what your subscription bills."

    /// The short form, for a notification body that has no room for the sentence —
    /// `CLIText`'s constant, so the notification and `omelette status` say it alike.
    static let apiEquivalentSuffix = CLIText.apiEquivalentSuffix

    /// nil for a pay-as-you-go account: there the dollars really are what gets billed,
    /// and a disclaimer would be worse than nothing.
    static func apiEquivalentCaption(isPayAsYouGo: Bool) -> String? {
        isPayAsYouGo ? nil : apiEquivalent
    }

    /// The caption for one provider's dollars on a dashboard page, where the provider
    /// may be missing from the snapshot (disabled, or not polled yet). An account that
    /// is not known to be pay-as-you-go gets the caption: saying "API-equivalent" of a
    /// bill is a smaller error than presenting an estimate as one.
    static func apiEquivalentCaption(for service: ServiceSnapshot?) -> String? {
        apiEquivalentCaption(isPayAsYouGo: service.map(isPayAsYouGo) ?? false)
    }

    /// Pay-as-you-go: the provider reports no rate-limit window of its own. That is
    /// exactly the shape `AppState.applyPayAsYouGo` keys off (Enterprise API billing
    /// returns no windows), and the only windows such an account can have are the
    /// synthetic ones above.
    static func isPayAsYouGo(_ service: ServiceSnapshot) -> Bool {
        // No window at all says "pay-as-you-go" only from a provider that is answering:
        // a signed-out or failing subscription has no windows either, and calling its
        // local dollars a bill would drop the API-equivalent caption exactly when the
        // numbers are least certain.
        if service.buckets.isEmpty { return service.state == .ok }
        return service.buckets.allSatisfy { syntheticBucketIDs.contains($0.id) }
    }

    /// "Last 7 days $12.40": the floating panel's one line for a healthy account with
    /// no window, in the words the All tab's tile uses for the same snapshot, and with
    /// its dollars printed the tile's way (currency format in the viewer's locale), so
    /// "$1,234.57" reads the same on both. No caption: an account with no window of its
    /// own is pay-as-you-go by the rule above, and there the dollars are the bill.
    static func lastSevenDays(_ dollars: Double, locale: Locale = .current) -> String {
        let amount = dollars.formatted(
            .currency(code: "USD").precision(.fractionLength(2)).locale(locale)
        )
        return "Last 7 days \(amount)"
    }
}
