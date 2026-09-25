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

// MARK: - CLI card

extension OverviewCopy {
    static let lastSevenDays = "Last 7 days"
    static let lastThirtyDays = "Last 30 days"
    /// History's own words for a log with nothing in it yet.
    static let noCLIUsage = "No CLI usage recorded yet"

    /// "Claude Code CLI · today": the log's name (`CostSource.shortName`) and the day.
    static func cliTitle(shortName: String?) -> String {
        "\(shortName ?? "CLI") · today"
    }

    /// "4,221 turns · 824.3M tokens": today's work under the headline.
    static func todayLine(turns: Int, tokens: Int, locale: Locale = .current) -> String {
        let count = turns == 1 ? "1 turn" : "\(turns.formatted(.number.locale(locale))) turns"
        return "\(count) · \(TokenFormat.formatTokens(tokens)) tokens"
    }
}

// MARK: - CLI card's bars

extension OverviewCopy {
    /// The strip's two ends.
    static let axisStart = "30 days ago"
    static let axisEnd = "Today"
}

// MARK: - CLI card's models

extension OverviewCopy {
    /// Over today's per-model rows.
    static let byModelTitle = "By model"

    /// "Opus 4.5 · 1.2M tokens · $41.20": the model, its tokens today and its dollars in
    /// the card's money format.
    static func modelLine(_ row: OverviewCLIRules.ModelRow, locale: Locale = .current) -> String {
        "\(row.model) · \(TokenFormat.formatTokens(row.tokens)) tokens · \(OMCostTile.money(row.cost, locale: locale))"
    }
}
