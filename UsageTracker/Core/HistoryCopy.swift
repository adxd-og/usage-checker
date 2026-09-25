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

// MARK: - Chart card

extension HistoryCopy {
    static func chartTitle(mode: HistoryChartMode) -> String {
        mode == .tokens ? "Tokens per day" : "Cost per day"
    }

    static func dayCount(_ n: Int) -> String {
        n == 1 ? "1 day" : "\(count(n)) days"
    }

    /// The Cost card's header: the range's days and their total, "7 days · $3,245.60".
    static func chartSummary(_ summary: HistoryRangeSummary) -> String {
        "\(dayCount(summary.dayCount)) · \(dollars(summary.cost))"
    }

    /// "$1,352.28".
    static func dollars(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(2)).locale(numberLocale))
    }

    /// The cost axis: "$1,500", or cents when a tick falls between dollars.
    static func costAxisLabel(_ value: Double) -> String {
        guard value == value.rounded() else { return dollars(value) }
        return "$" + value.formatted(.number.precision(.fractionLength(0)).locale(numberLocale))
    }

    /// The tokens axis: "500M", "1,000M", "1.5M", "250k".
    static func tokenAxisLabel(_ value: Double) -> String {
        func compact(_ v: Double) -> String {
            v.formatted(.number.precision(.fractionLength(0...1)).locale(numberLocale))
        }
        if abs(value) >= 1_000_000 { return compact(value / 1_000_000) + "M" }
        if abs(value) >= 1_000 { return compact(value / 1_000) + "k" }
        return compact(value)
    }

    /// A cost bar's figure: whole dollars from $10 ("$1,352"), cents below.
    static func costBarLabel(_ value: Double) -> String {
        guard value >= 10 else { return dollars(value) }
        return "$" + value.rounded().formatted(.number.precision(.fractionLength(0)).locale(numberLocale))
    }

    static func tokenBarLabel(_ tokens: Int) -> String {
        TokenFormat.formatTokens(tokens)
    }

    /// A date under the bars, in the chat list's own spelling ("30 Aug", "Aug 30").
    static func axisDay(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        SessionCopy.dayText(date, calendar: calendar, locale: locale)
    }

    static let emptyChartTitle = "No CLI usage in this range"

    static func emptyChartHint(command: String) -> String {
        "Run a `\(command)` session to start collecting data"
    }
}

// MARK: - Tooltip

extension HistoryCopy {
    /// "Wed, 2 Sep" (en_GB) or "Wed, Sep 2" (en_US): the weekday, then the day the chat
    /// list's own way. `withTime` adds " · 14:05" for a chart of hours.
    static func tooltipTitle(
        _ date: Date, withTime: Bool = false,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let weekday = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated)
        )
        let day = "\(weekday), \(SessionCopy.dayText(date, calendar: calendar, locale: locale))"
        return withTime ? "\(day) · \(time(date, calendar: calendar, locale: locale))" : day
    }

    /// "14:05" / "2:05 PM", the user's clock.
    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ))
    }
}

// MARK: - Quota chart

extension HistoryCopy {
    /// "29%".
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// The quota chart's time axis: the hour for a day, the month for a year, the day
    /// between.
    static func quotaAxisLabel(
        _ date: Date, range: TimeRange, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        switch range {
        case .fiveHours, .oneDay:
            return time(date, calendar: calendar, locale: locale)
        case .oneYear:
            return date.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .month(.abbreviated)
            )
        case .sevenDays, .thirtyDays, .ninetyDays:
            return SessionCopy.dayText(date, calendar: calendar, locale: locale)
        }
    }

    static func noQuotaTitle(provider: String) -> String {
        "No quota recorded yet for \(provider)"
    }

    static let noQuotaHint = "Windows are recorded on every successful poll — this fills in as the app runs."
}

// MARK: - Quota-only note

extension HistoryCopy {
    /// Why a provider's History has a quota chart and nothing else. `provider` is the
    /// service id: the reason differs per provider (`DashboardState.costSource`).
    static func quotaOnlyNote(provider: String) -> String {
        let rest = "so there are no costs or sessions here. Quota over time is charted instead."
        switch provider {
        case "antigravity":
            return "Antigravity keeps no local token log, \(rest)"
        case "gemini":
            return "Omelette doesn't read the Gemini CLI's token log, \(rest)"
        default:
            return "\(QuotaAnalytics.prettifiedLabel(for: provider)) keeps no local token log, \(rest)"
        }
    }
}
