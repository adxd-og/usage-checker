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

// MARK: - Controls

extension HistoryCopy {
    /// What VoiceOver calls the Cost/Tokens switch.
    static let modePickerLabel = "Unit"
}

// MARK: - Sessions card

extension HistoryCopy {
    /// Counts and dollars are grouped the US way ("1,729", "$1,352.28") whatever the
    /// Mac's region, like every "$" figure in the app, so a count never reads
    /// differently from the dollars beside it.
    static let numberLocale = Locale(identifier: "en_US")

    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(numberLocale))
    }

    static let sessionsTitle = "Sessions"

    /// "4 of 103" while the list is cut, "103" when it is all of them.
    static func sessionCount(shown: Int, total: Int) -> String {
        shown < total ? "\(count(shown)) of \(count(total))" : count(total)
    }

    /// The column titles, in the order the wide row draws them.
    static let sessionColumns = ["Session", "Last active", "Turns", "Tokens", "Cost"]

    /// The line under a chat's name: its project, then what 2.x wore as chips — the
    /// chat is on the list for what it cost, or an agent drove it (`exec`).
    static func sessionSubtitle(project: String, isTop: Bool, origin: String?) -> String {
        var parts = [project]
        if isTop { parts.append(SessionCopy.topSpendChip) }
        if let origin = SessionCopy.originChip(origin) { parts.append(origin) }
        return parts.joined(separator: " · ")
    }

    static func turns(_ n: Int) -> String {
        n == 1 ? "1 turn" : "\(count(n)) turns"
    }

    /// A narrow row's figures, folded onto one line under the name.
    static func narrowCaption(lastActive: String, turns: Int, tokens: Int) -> String {
        [lastActive, Self.turns(turns), "\(TokenFormat.formatTokens(tokens)) tokens"]
            .joined(separator: " · ")
    }

    /// What VoiceOver calls the Recent/Cost switch of the whole list.
    static let sortPickerLabel = "Sort"
}

// MARK: - An open chat

extension HistoryCopy {
    /// Unpriced chats (a provider that prices a turn as a whole) still show their token
    /// split, under a title that does not promise dollars.
    static func moneyTitle(hasCost: Bool) -> String {
        hasCost ? "Where the money went" : "Tokens by type"
    }

    static let thinkingLabel = "Thinking"
    /// Thinking is part of output, so its cell says so instead of pricing it twice.
    static let thinkingNote = "in output"
    static let subAgentsTitle = "Sub-agents"
    static let agentColumns = ["Agent", "Model", "Effort", "Turns", "Tokens", "Cost"]
    static let dayColumns = ["Day", "Turns", "Tokens", "Cost"]

    /// A sub-agent row in a narrow list: the columns after the name, blanks dropped.
    static func agentCaption(_ row: HistoryAgentRow) -> String {
        [row.model, row.effort, "\(row.turns) turns", row.tokens]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
