import Foundation

/// Every string the Limits tab shows: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab and § Accounts without
/// percent windows, in the words of `Dashboard-Limits(-Light).dc.html`. Each `extension`
/// below is one part of the page.
///
/// A share is percent points of a limit window, a budget, a period's spend or a spend
/// limit. Dollars are US-grouped after a "$" whatever the Mac's region, as History's
/// (`HistoryCopy.numberLocale`).
enum LimitsCopy {}

// MARK: - Figures

extension LimitsCopy {
    /// Shares under this many points read "< 0.1 %" (§ The tab, item 3).
    static let shareFloor: Double = 0.1

    /// "≈ 4.2 %": a chat's, a project's or Outside's points, to one decimal. Under a
    /// tenth of a point it reads "< 0.1 %", a chat whose half hours moved nothing
    /// included: with whole-number percents its quota shows in a later step.
    static func share(_ points: Double) -> String {
        guard points + LimitShareRules.pointSlack >= shareFloor else { return "< 0.1 %" }
        return String(format: "≈ %.1f %%", points)
    }

    /// "≈ 2 %": Outside this Mac on a Claude subscription. It takes whole half hours of
    /// whole-number percents, so it is whole points (§ The tab, item 2).
    static func wholeShare(_ points: Double) -> String {
        "≈ \(Int(points.rounded())) %"
    }

    /// "$1,358", "$62", "$6.20": whole dollars from $10, as the mockup prints them; cents
    /// below, where a whole dollar would hide the figure.
    static func dollars(_ amount: Double) -> String {
        let digits = abs(amount) >= 10 ? 0 : 2
        return amount.formatted(
            .currency(code: "USD").precision(.fractionLength(digits)).locale(HistoryCopy.numberLocale)
        )
    }

    /// "130 M", "9.5 M", "2.5 B", "84 k": a token count and its unit, whole from ten of a
    /// unit, one decimal below.
    static func tokens(_ count: Double) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            String(format: value >= 10 ? "%.0f" : "%.1f", value) + " " + unit
        }
        if count >= 1_000_000_000 { return scaled(count / 1_000_000_000, "B") }
        if count >= 1_000_000 { return scaled(count / 1_000_000, "M") }
        if count >= 1_000 { return scaled(count / 1_000, "k") }
        return String(format: "%.0f", count)
    }
}

// MARK: - A page without cards

extension LimitsCopy {
    static let unsupported = "Limit analytics needs a chat-level cost log. Claude and Codex have one."
    static let loading = "Loading…"
    static let noSpend = "Nothing spent in the last 7 days."

    /// An account that reports no window, budget or spend limit: signed out, or not
    /// polled yet.
    static func nothingToMeasure(providerName: String) -> String {
        "\(providerName) has reported no limit to measure yet."
    }

    /// A subscription whose window has no reset time yet: it opens with the next message.
    static func noOpenWindow(_ span: LimitsSpan) -> String {
        switch span {
        case .session: return "No session window is open right now."
        case .week: return "No weekly window is open right now."
        case .month: return "No monthly window is open right now."
        }
    }

    /// The sentence a page shows in place of its cards; nil for the page with cards.
    static func message(for page: LimitsPage, providerName: String) -> String? {
        switch page {
        case .unsupported: return unsupported
        case .nothingToMeasure: return nothingToMeasure(providerName: providerName)
        case .noOpenWindow(let span): return noOpenWindow(span)
        case .loading: return loading
        case .noSpend: return noSpend
        case .ready: return nil
        }
    }
}

// MARK: - Window switch

extension LimitsCopy {
    /// What VoiceOver calls the Session / Week switch.
    static let windowPickerLabel = "Limit window"

    /// A segment of the switch: "Session", "Week", or "Month" for Codex Free's 30 days.
    static func windowName(_ span: LimitsSpan) -> String {
        switch span {
        case .session: return "Session"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

// MARK: - Header

extension LimitsCopy {
    /// The page's title: the sidebar's name for the tab (`DashboardTab.limits`).
    static let title = "Limits"
    static let subtitle = "Limit analytics"
}

// MARK: - The first card

/// The Limits tab's first card as `LimitsTopCard` draws it (`Dashboard-Limits.dc.html`,
/// "Price of a percent").
struct LimitsTopCardText: Equatable, Sendable {
    let title: String
    /// On the title's baseline: when the period began.
    let trailing: String
    /// The figure ("1 % ≈ $62", "$412 of $500 budget"), or a sentence in its place.
    let value: String
    /// True for a figure, drawn large; false for "Not enough use yet".
    let valueIsFigure: Bool
    /// Beside the figure: "≈ 130 M tokens".
    let detail: String?
    /// Under the figure: what the dollars are. nil where they are the bill.
    let caption: String?
    /// Under everything: the weekly budget in Settings, on Claude pay as you go.
    let link: String?
}

extension LimitsCopy {
    static let priceTitle = "Price of a percent"
    static let notEnoughUse = "Not enough use yet"
    /// What a subscription's dollars are (§ Accounts without percent windows, Cost
    /// caption). Said once, on this card; the rows' dollars are the same kind.
    static let apiListCaption = "API-list prices, not your bill"
    static let budgetTitle = "Weekly budget"
    static let spendTitle = "Spend"
    static let spendLimitTitle = "Spend limit"
    static let lastSevenDays = "last 7 days"
    static let setBudget = "Set a weekly budget"
    static let changeBudget = "Change the budget"

    /// The link to the weekly budget in Settings: Claude's only, since Codex has no budget
    /// setting. "Set" when none is set, "Change" when one is.
    static func budgetLink(serviceID: String, budget: Double?) -> String? {
        guard serviceID == "claude" else { return nil }
        return budget == nil ? setBudget : changeBudget
    }

    /// The link under a page's sentence: on Claude pay as you go with nothing spent and no
    /// budget, the budget to set. nil on every other page.
    static func messageLink(for page: LimitsPage, serviceID: String) -> String? {
        guard case .noSpend = page else { return nil }
        return budgetLink(serviceID: serviceID, budget: nil)
    }

    /// "1 % ≈ $62"
    static func priceValue(_ price: PercentPrice) -> String {
        "1 % ≈ \(dollars(price.dollars))"
    }

    /// "≈ 130 M tokens"
    static func priceTokens(_ price: PercentPrice) -> String {
        "≈ \(tokens(price.tokens)) tokens"
    }

    /// "since Tue 12:00", "since today 8:00": when the window began, on History's ladder
    /// (`SessionCopy.lastActive`), to the nearest minute (`LimitsRules.toMinute`). A reset
    /// at 12:59:59 opened its session at 8:00, not 7:59.
    static func since(
        _ start: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        "since " + SessionCopy.lastActive(
            LimitsRules.toMinute(start), now: now, style: .sentence, calendar: calendar, locale: locale
        )
    }

    /// "since 1 Sep": a spend limit's month, which starts on a day.
    static func sinceDay(_ start: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "since " + SessionCopy.dayText(start, calendar: calendar, locale: locale)
    }

    /// "$412 of $500 budget"
    static func budgetValue(spent: Double, budget: Double) -> String {
        "\(dollars(spent)) of \(dollars(budget)) budget"
    }

    /// "$412 in 7 days"
    static func spendValue(_ spent: Double) -> String {
        "\(dollars(spent)) in 7 days"
    }

    /// "$1,240 of $2,000 this month": the server's used credits against the limit.
    static func spendLimitValue(used: Double, limit: Double) -> String {
        "\(dollars(used)) of \(dollars(limit)) this month"
    }

    /// The first card of `load`'s mode (§ Accounts without percent windows, Top card):
    /// - Subscription: the price of a percent in API-list dollars and tokens, or "Not
    ///   enough use yet" below one attributed point;
    /// - Pay as you go: the last 7 days' spend, against the weekly budget when one is set.
    ///   The dollars are the bill, so there is no caption. On Claude the card links to the
    ///   budget in Settings (`budgetLink`);
    /// - Spend limit: the server's dollars this month against the limit.
    static func topCard(
        for load: DashboardState.LimitShareLoad,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LimitsTopCardText {
        let share = load.share
        switch load.request.mode {
        case .subscription:
            return LimitsTopCardText(
                title: priceTitle,
                trailing: since(share.window.start, now: now, calendar: calendar, locale: locale),
                value: share.price.map { priceValue($0) } ?? notEnoughUse,
                valueIsFigure: share.price != nil,
                detail: share.price.map { priceTokens($0) },
                caption: apiListCaption,
                link: nil
            )
        case .payAsYouGo(let budget):
            return LimitsTopCardText(
                title: budget == nil ? spendTitle : budgetTitle,
                trailing: lastSevenDays,
                value: budget.map { budgetValue(spent: share.cost, budget: $0) } ?? spendValue(share.cost),
                valueIsFigure: true,
                detail: nil,
                caption: nil,
                link: budgetLink(serviceID: load.serviceID, budget: budget)
            )
        case .spendLimit(let limit, let used):
            return LimitsTopCardText(
                title: spendLimitTitle,
                trailing: sinceDay(share.window.start, calendar: calendar, locale: locale),
                value: spendLimitValue(used: used, limit: limit),
                valueIsFigure: true,
                detail: nil,
                caption: nil,
                link: nil
            )
        }
    }
}

// MARK: - What filled the window

extension LimitsCopy {
    /// The ranked card's title: the window, the budget, the spend or the limit it splits.
    static func rankedTitle(mode: LimitMode, span: LimitsSpan) -> String {
        switch mode {
        case .subscription:
            switch span {
            case .session: return "What filled this session"
            case .week: return "What filled this week"
            case .month: return "What filled this month"
            }
        case .payAsYouGo(let budget):
            return budget == nil ? "Where the spend went" : "What filled the budget"
        case .spendLimit:
            return "What filled this month's limit"
        }
    }

    /// On the title's baseline: how full the window, budget or limit is, in whole points;
    /// without a budget, what the shares are of.
    static func rankedTrailing(mode: LimitMode, percent: Double) -> String {
        let whole = Int(percent.rounded())
        switch mode {
        case .subscription:
            return "\(whole) % so far"
        case .payAsYouGo(let budget):
            return budget == nil ? "% of spend in 7 days" : "\(whole) % of budget"
        case .spendLimit:
            return "\(whole) % of limit"
        }
    }

    /// In place of the rows when the period has no chat on this Mac.
    static func noChats(mode: LimitMode, span: LimitsSpan) -> String {
        switch mode {
        case .subscription:
            switch span {
            case .session: return "No chats in this session yet"
            case .week: return "No chats this week yet"
            case .month: return "No chats this month yet"
            }
        case .payAsYouGo:
            return "No chats in the last 7 days"
        case .spendLimit:
            return "No chats this month yet"
        }
    }

    /// "Show all (23)" under a capped list, "Show fewer" once it is open.
    static func showAll(count: Int, expanded: Bool) -> String {
        expanded ? "Show fewer" : "Show all (\(HistoryCopy.count(count)))"
    }
}

// MARK: - Under the ranked rows

extension LimitsCopy {
    static let outsideTitle = "Outside this Mac"
    static let earlierTitle = "Earlier this month"
    static let earlierSubtitle = "This Mac, not split by chat"

    /// Where Outside this Mac's use comes from, in the provider's own words.
    static func outsideSubtitle(serviceID: String) -> String {
        switch serviceID {
        case "claude": return "claude.ai, the desktop app or another machine"
        case "codex": return "another Codex client or another machine"
        default: return "another app or another machine"
        }
    }

    /// Under a spend limit's rows: their dollars are API-list prices, and the limit is
    /// billed at the organisation's rate (§ Accounts without percent windows, Cost
    /// caption). A subscription says it on its first card; pay as you go's dollars are
    /// the bill.
    static func rowsFootnote(mode: LimitMode) -> String? {
        if case .spendLimit = mode { return "API-list prices; your organisation's rate may differ" }
        return nil
    }
}
