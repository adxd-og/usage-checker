import Foundation

/// Every string History puts on screen (liquid-glass spec § Screens, the History rows;
/// § Components, "Chart tooltip"). Dollars and counts are US-grouped after a "$", as the
/// app's other figures; dates follow the user's locale. Each `extension` below is one
/// part of the page.
enum HistoryCopy {
    static let title = "History"

    /// The one line under the title: where the numbers come from and, for dollars on a
    /// subscription, that they are what the same tokens would cost through the API.
    /// Said once for the page, so no caption repeats it under a card.
    static func subtitle(
        showsQuota: Bool, providerName: String, sourceName: String?, isPayAsYouGo: Bool
    ) -> String {
        if showsQuota { return "How full \(providerName) usage windows ran" }
        let source = sourceName ?? "local CLI logs"
        return isPayAsYouGo
            ? "Cost from \(source)"
            : "API-equivalent cost from \(source), not your subscription bill"
    }
}
