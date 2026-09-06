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

    /// The short form, for a notification body that has no room for the sentence.
    static let apiEquivalentSuffix = "(API-equivalent)"

    /// nil for a pay-as-you-go account: there the dollars really are what gets billed,
    /// and a disclaimer would be worse than nothing.
    static func apiEquivalentCaption(isPayAsYouGo: Bool) -> String? {
        isPayAsYouGo ? nil : apiEquivalent
    }

    /// Pay-as-you-go: the provider reports no rate-limit window of its own. That is
    /// exactly the shape `AppState.applyPayAsYouGo` keys off (Enterprise API billing
    /// returns no windows), and the only windows such an account can have are the
    /// synthetic ones above.
    static func isPayAsYouGo(_ service: ServiceSnapshot) -> Bool {
        service.buckets.allSatisfy { syntheticBucketIDs.contains($0.id) }
    }
}
