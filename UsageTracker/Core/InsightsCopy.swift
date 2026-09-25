import Foundation

/// One figure as the Insights tab prints it.
struct InsightsFigureText: Equatable, Sendable {
    let title: String
    let value: String
    /// Beside the value, in the accent: This week vs last's change.
    let delta: String?
    let caption: String?
}

/// Every string the Insights tab shows (liquid-glass spec § Screens, "Insights"). The
/// words are `Dashboard-Insights(-Light).dc.html`'s.
enum InsightsCopy {
    /// A figure with nothing to say yet.
    static let noValue = "—"

    /// Dollars as the popover prints them ("$2,727.56"), in the viewer's locale. Every
    /// dollar on the tab is an API-list-price figure from a local log; the page's
    /// footnote says so once.
    static func money(_ dollars: Double, locale: Locale = .current) -> String {
        OMCostTile.money(dollars, locale: locale)
    }

    // MARK: - Figures

    /// What `figure` says for `summary`. `quotaBuckets` names the busiest quota day's
    /// window; `calendar` and `locale` print dates and hours.
    static func text(
        for figure: InsightsFigure,
        summary: InsightsSummary,
        quotaBuckets: [QuotaBucketInfo],
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> InsightsFigureText {
        switch figure {
        case .weekOverWeek:
            let week = summary.weekOverWeek
            return InsightsFigureText(
                title: weekOverWeekTitle,
                value: money(week.thisWeek, locale: locale),
                delta: weekDelta(week),
                caption: lastWeek(week.lastWeek, locale: locale)
            )
        case .daysAtLimit:
            return InsightsFigureText(
                title: daysAtLimitTitle,
                value: daysAtLimitValue(summary.daysAtLimit),
                delta: nil,
                caption: daysAtLimitCaption
            )
        case .dailyAverage:
            let average = summary.dailyAverage
            return InsightsFigureText(
                title: dailyAverageTitle,
                value: average.average.map { money($0, locale: locale) } ?? noValue,
                delta: nil,
                caption: activeDays(average.activeDays)
            )
        case .biggestDay:
            return InsightsFigureText(
                title: biggestDayTitle,
                value: summary.biggestDay.map { money($0.cost, locale: locale) } ?? noValue,
                delta: nil,
                caption: summary.biggestDay.map { day($0.day, calendar: calendar) }
            )
        case .mostUsedModelToday:
            return InsightsFigureText(
                title: mostUsedModelTodayTitle,
                value: summary.mostUsedModelToday?.model ?? noValue,
                delta: nil,
                caption: summary.mostUsedModelToday.map { money($0.cost, locale: locale) }
            )
        case .averageDailyPeak:
            return InsightsFigureText(
                title: averageDailyPeakTitle,
                value: summary.quota.averageDailyPeak.map { percent($0) } ?? noValue,
                delta: nil,
                caption: summary.quota.todayPeak.map { soFarToday($0) }
            )
        case .quotaPerDay:
            return InsightsFigureText(
                title: quotaPerDayTitle,
                value: summary.quota.averageDailyConsumption.map { percent($0) } ?? noValue,
                delta: nil,
                caption: quotaPerDayCaption
            )
        case .busiestQuotaDay:
            let busiest = summary.quota.busiestDay
            return InsightsFigureText(
                title: busiestQuotaDayTitle,
                value: busiest.map { percent($0.peak) } ?? noValue,
                delta: nil,
                caption: busiest.map { peak in
                    "\(day(peak.day, calendar: calendar)) · "
                        + InsightsRules.windowLabel(for: peak.peakBucketID, in: quotaBuckets)
                }
            )
        case .busiestHour:
            return InsightsFigureText(
                title: busiestHourTitle,
                value: summary.quota.busiestHour.map { hour($0, calendar: calendar, locale: locale) } ?? noValue,
                delta: nil,
                caption: busiestHourCaption
            )
        }
    }

    // MARK: - This week vs last

    static let weekOverWeekTitle = "This week vs last"

    /// "Last week $2,199.10"
    static func lastWeek(_ dollars: Double, locale: Locale = .current) -> String {
        "Last week " + money(dollars, locale: locale)
    }

    /// "↑ 24%" / "↓ 12%": this week's change on last week in whole percent, "0%" when it
    /// rounds to nothing. nil when last week had no spend: a change on nothing is no
    /// percentage.
    static func weekDelta(_ week: WeekOverWeek) -> String? {
        guard week.lastWeek > 0, let delta = week.deltaPercent else { return nil }
        let magnitude = abs(Int(delta.rounded()))
        guard magnitude > 0 else { return "0%" }
        return "\(delta > 0 ? "↑" : "↓") \(magnitude)%"
    }

    // MARK: - Days at limit

    static let daysAtLimitTitle = "Days at limit, 7 days"

    /// "3 of 7": the mockup's `[n] of 7`.
    static func daysAtLimit(_ days: Int) -> String {
        "\(days) of \(InsightsRules.daysAtLimitSpan)"
    }

    /// The card's value. `noValue` when not one of the seven days has a reading:
    /// "0 of 7" would vouch for a week the app never saw.
    static func daysAtLimitValue(_ days: QuotaDaysAtCapacity) -> String {
        days.observed == 0 ? noValue : daysAtLimit(days.atCapacity)
    }

    /// "days the peak reached 95%", worded from the threshold that decides the count.
    static var daysAtLimitCaption: String {
        String(format: "days the peak reached %.0f%%", QuotaAnalytics.capacityThreshold)
    }

    // MARK: - Daily average, biggest day, most-used model

    static let dailyAverageTitle = "Daily average, 30 days"

    /// "29 active days" / "1 active day"
    static func activeDays(_ days: Int) -> String {
        days == 1 ? "1 active day" : "\(days) active days"
    }

    static let biggestDayTitle = "Biggest day"

    static let mostUsedModelTodayTitle = "Most-used model today"

    // MARK: - Quota figures (a provider without a cost log)

    static let averageDailyPeakTitle = "Average daily peak"
    static let quotaPerDayTitle = "Quota used per day"
    static let quotaPerDayCaption = "of a window, resets counted"
    static let busiestQuotaDayTitle = "Busiest day"
    static let busiestHourTitle = "Busiest hour"
    static let busiestHourCaption = "when the quota climbs most"

    /// "72%": a quota figure in whole percent.
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// "55% so far today"
    static func soFarToday(_ peak: Double) -> String {
        String(format: "%.0f%% so far today", peak)
    }

    /// An hour of the day on the user's own clock: "14:00", or "2:00 PM" where the user
    /// reads 12-hour time. Printed from a fixed winter day, so no clock change can
    /// swallow the hour asked about.
    static func hour(_ hour: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: hour)) else {
            return String(format: "%02d:00", hour)
        }
        // The locale's own short time ("09:00" in en_GB, "9:00 AM" in en_US).
        // `Date.FormatStyle`'s `.shortened` drops the leading zero on macOS 27 ("9:00").
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Session window

    static let sessionWindowTitle = "Current session window"

    /// "since 10:30": when the open window began, on the user's own clock.
    static func since(_ start: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone
        )
        return "since \(start.formatted(style))"
    }

    /// A window with no CLI turns in it: the percentage came from somewhere the logs
    /// cannot see, and the card says so rather than implying nothing happened. Named
    /// after the provider's own tools; only Claude and Codex have a session window and a
    /// cost log today, and anything else gets the neutral sentence.
    static func emptySession(providerID: String) -> String {
        switch providerID {
        case "claude":
            return "No Claude Code activity in this window. Whatever the session limit is showing came from somewhere else — the Claude apps, or another machine on this account."
        case "codex":
            return "No Codex activity in this window. Whatever the session limit is showing came from somewhere else — another Codex client, or another machine on this account."
        default:
            return "No activity from the CLI in this window. Whatever the session limit is showing came from somewhere else — another app, or another machine on this account."
        }
    }

    static let byProject = "By project"

    /// The split's third slice when more than three models have dollars: every model
    /// past the top two.
    static let otherModels = "Other"

    /// "1,742 turns" / "1 turn", grouped in the viewer's locale.
    static func turns(_ count: Int, locale: Locale = .current) -> String {
        count == 1 ? "1 turn" : "\(count.formatted(.number.locale(locale))) turns"
    }

    // MARK: - Dates

    /// "2 Sep 2026": the mockup's date. Pinned to `en_US_POSIX` and the calendar's own
    /// zone, as `AgentHistorySummary.dayTitle` is: the app's words are English, and the
    /// date has to name the day the figure was binned into.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        // Built per call: a card asks once per render, and a shared mutable formatter
        // would need a lock (this is nonisolated).
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
