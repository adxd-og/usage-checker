import SwiftUI

/// The Overview's own words (liquid-glass spec § Screens, "Overview";
/// `Dashboard-Overview(-Light).dc.html`). Each card's lines arrive with the card.
enum OverviewCopy {
    /// The rings card's legend.
    static let legendTitle = "Usage windows"

    /// "Burn rate: idle": `OverviewView.burnValue`'s answer, lower case after the colon.
    static func burnLine(burn: BurnRatePrediction?, retained: Bool) -> String {
        let value = OverviewView.burnValue(burn, retained: retained)
        return "Burn rate: \(value.prefix(1).lowercased())\(value.dropFirst())"
    }

    /// The legend's last line: the burn verdict in its colour when there is one (amber
    /// when the limit will be hit), else the burn line in secondary.
    static func footer(verdict: BurnVerdict?, burn: BurnRatePrediction?, retained: Bool) -> OverviewLine {
        if let verdict {
            return OverviewLine(text: verdict.text, token: OMHero.verdictToken(verdict))
        }
        return OverviewLine(text: burnLine(burn: burn, retained: retained), token: .secondary)
    }
}

// MARK: - Header

extension OverviewCopy {
    /// The line under the provider's name: its plan and how fresh its numbers are,
    /// "Max 20x · updated 7s ago" (`UpdatedCopy`'s words, lower case after the plan). A live
    /// provider's age is the poll's, the sidebar footnote's source (the two may lag by one
    /// 5 s tick); last-known numbers are as old as their own reading. nil when the provider
    /// is not in the snapshot.
    static func subtitle(service: ServiceSnapshot?, snapshotFetchedAt: Date, now: Date) -> String? {
        guard let service else { return nil }
        let fetchedAt = service.isRetained ? service.fetchedAt : snapshotFetchedAt
        let updated = UpdatedCopy.text(fetchedAt: fetchedAt, now: now)
        guard let plan = PopoverCopy.planLine(plan: service.plan, displayName: service.displayName) else {
            return updated
        }
        return "\(plan) · \(updated.prefix(1).lowercased())\(updated.dropFirst())"
    }
}
