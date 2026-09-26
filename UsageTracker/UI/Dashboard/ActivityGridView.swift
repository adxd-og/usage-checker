import SwiftUI

/// History → Calendar (liquid-glass spec § Screens, "History · Calendar"): the
/// GitHub-style heatmap over the page's range, today ringed, one total for the range.
/// Cost squares climb the yolk ramp in four steps (`HistoryCalendarRules`); a quota-only
/// provider's squares are its daily peak over the core windows, in the gauge colours,
/// as the Activity tab drew them. Cost only: the Tokens unit never reaches here (spec
/// § Decisions, "Calendar in Tokens mode").
struct ActivityGridView: View {
    @ObservedObject var dashboard: DashboardState
    /// The page's range, one History offers (`HistoryRules.offeredRange`).
    let range: TimeRange

    @State private var cache: GridCache?
    @State private var quotaSummary: HistoryCalendarQuotaSummary?
    @Environment(\.colorScheme) private var colorScheme

    private let cellSize = HistoryLayout.calendarCellSize
    private let spacing = HistoryLayout.calendarCellSpacing

    /// Providers with no local cost log get a grid of daily *quota* peaks instead of a
    /// dead end — for a subscription that is the same story in the only unit available.
    private var showsQuota: Bool { !dashboard.costSource.hasBreakdown }

    var body: some View {
        VStack(alignment: .leading, spacing: HistoryLayout.calendarCardSpacing) {
            if showsQuota, cache?.hasData == false {
                noQuotaPlaceholder
            } else if let cache {
                header(cache)
                gridBlock(cache)
                if let note = Self.retentionNote(provider: dashboard.selectedService, showsQuota: showsQuota) {
                    Text(note)
                        .font(.system(size: HistoryLayout.noteSize))
                        .foregroundStyle(.om(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                placeholder
            }
        }
        .padding(HistoryLayout.calendarCardPadding)
        .dashboardCard(padding: 0)
        .task(id: taskKey) {
            await rebuildCache()
        }
    }

    private var taskKey: TaskKey {
        TaskKey(
            range: range,
            service: dashboard.selectedService,
            cliUpdatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast,
            historyCount: dashboard.history.count,
            lastHistoryAt: dashboard.history.last?.timestamp ?? .distantPast,
            bucketIDs: dashboard.quotaBuckets.map(\.id),
            day: HistoryRules.cacheDay(now: Date(), calendar: .current)
        )
    }

    @MainActor
    private func rebuildCache() async {
        let started = taskKey
        let range = self.range
        let now = Date()
        let calendar = Calendar.current
        let windowStart = HistoryRules.windowStart(range: range, now: now, calendar: calendar)
        let weeks = HistoryCalendarRules.weeks(from: windowStart, now: now, calendar: calendar)
        // Heavy work off the main actor, whichever metric the grid is showing.
        let built: GridCache
        let summary: HistoryCalendarQuotaSummary?
        if showsQuota {
            let records = dashboard.history
            let buckets = dashboard.quotaBuckets
            let result = await Task.detached(priority: .userInitiated) { () -> (GridCache, HistoryCalendarQuotaSummary) in
                let grid = GridCache.build(
                    records: HistoryCalendarRules.quotaRecords(records, range: range, now: now, calendar: calendar),
                    buckets: buckets, weeks: weeks,
                    now: now, calendar: calendar, notBefore: windowStart
                )
                let summary = HistoryCalendarRules.quotaSummary(
                    records: records, buckets: buckets, range: range, now: now, calendar: calendar
                )
                return (grid, summary)
            }.value
            built = result.0
            summary = result.1
        } else {
            // The range's rows only (`HistoryCalendarRules.costRows`), so the ramp's top
            // step is the range's busiest day.
            let dailies = HistoryCalendarRules.costRows(
                dashboard.cliBreakdown?.daily ?? [], range: range, now: now, calendar: calendar
            )
            built = await Task.detached(priority: .userInitiated) {
                GridCache.build(from: dailies, weeks: weeks, now: now, calendar: calendar, notBefore: windowStart)
            }.value
            summary = nil
        }
        // See `DerivedCacheGate`: the await does not stop when `.task(id:)` cancels this
        // pass, and a slow pass for the provider or range just left would land last.
        guard DerivedCacheGate.canPublish(
            started: started, current: taskKey, cancelled: Task.isCancelled
        ) else { return }
        cache = built
        quotaSummary = summary
    }

    /// The same days and the same sum as the Chart card's header (`HistoryRules`).
    private var costSummary: HistoryRangeSummary {
        let now = Date()
        let days = HistoryRules.days(
            daily: dashboard.cliBreakdown?.daily ?? [], range: range, now: now, calendar: .current
        )
        return HistoryRules.summary(days, range: range, now: now, calendar: .current)
    }

    /// Title, the range's one figure, and the legend on the right.
    private func header(_ c: GridCache) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(HistoryCopy.calendarTitle(range: range, showsQuota: showsQuota))
                .font(.system(size: HistoryLayout.cardTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
            if showsQuota {
                if let summary = quotaSummary,
                   let text = HistoryCopy.daysAtLimit(summary.daysAtLimit, of: summary.daysObserved) {
                    Text(text)
                        .font(.system(size: HistoryLayout.cardCaptionSize))
                        .foregroundStyle(.om(.secondary))
                }
            } else {
                let summary = costSummary
                Text(HistoryCopy.dollars(summary.cost))
                    .font(OMFont.numerals(size: HistoryLayout.calendarTotalSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                Text(HistoryCopy.activeDays(summary.activeDays))
                    .font(.system(size: HistoryLayout.cardCaptionSize))
                    .foregroundStyle(.om(.secondary))
            }
            Spacer(minLength: 12)
            legend(c)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(HistoryCopy.calendarLoading)
                .font(OMFont.caption)
                .foregroundStyle(.om(.secondary))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// Quota history only starts when the app first polls this provider successfully,
    /// so a fresh provider has an honest reason for an empty grid.
    private var noQuotaPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.largeTitle)
                .foregroundStyle(.om(.muted))
            Text(HistoryCopy.noQuotaTitle(provider: dashboard.displayName(for: dashboard.selectedService)))
                .foregroundStyle(.om(.secondary))
            Text(HistoryCopy.noQuotaHint)
                .font(OMFont.body)
                .foregroundStyle(.om(.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// The grid scrolls sideways when the column is narrower than its weeks, and opens
    /// on this week.
    private func gridBlock(_ c: GridCache) -> some View {
        let column = cellSize + spacing
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: HistoryLayout.calendarWeekdayGap) {
                weekdayLabels
                VStack(alignment: .leading, spacing: HistoryLayout.calendarMonthGap) {
                    monthLabels(c, column: column)
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<c.weeksMatrix.count, id: \.self) { w in
                            VStack(spacing: spacing) {
                                ForEach(0..<7, id: \.self) { d in
                                    cell(c.weeksMatrix[w][d], cache: c)
                                }
                            }
                        }
                    }
                }
            }
            // Room for today's ring at the clip edges (`HistoryLayout.calendarGridEdgeInset`).
            .padding(.bottom, HistoryLayout.calendarGridEdgeInset)
            .padding(.trailing, HistoryLayout.calendarGridEdgeInset)
        }
        .defaultScrollAnchor(.trailing)
    }

    private func monthLabels(_ c: GridCache, column: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(c.monthMarkers, id: \.weekIndex) { marker in
                Text(marker.label)
                    .font(.system(size: HistoryLayout.calendarMonthSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize()
                    .offset(x: CGFloat(marker.weekIndex) * column)
            }
        }
        .frame(
            width: CGFloat(c.weeksMatrix.count) * column,
            height: HistoryLayout.calendarMonthRowHeight,
            alignment: .leading
        )
    }

    private var weekdayLabels: some View {
        let labels = GridCache.weekdayLabels(calendar: .current)
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<7, id: \.self) { d in
                Text(labels[d])
                    .font(.system(size: HistoryLayout.calendarWeekdaySize))
                    .foregroundStyle(.om(.secondary))
                    .frame(width: HistoryLayout.calendarWeekdayWidth, height: cellSize, alignment: .leading)
            }
        }
        .padding(.top, HistoryLayout.calendarMonthRowHeight + HistoryLayout.calendarMonthGap)
    }

    private func cell(_ day: Day, cache: GridCache) -> some View {
        let intensity = cache.scaleMax > 0 ? min(1.0, day.value / cache.scaleMax) : 0
        // A day the app never observed is not a day of no usage. Only the quota grid
        // can tell the two apart, so only it draws the difference.
        let unobserved = cache.dimsUnrecordedDays && !day.hasReading
        let fill: Color
        if day.isBlank {
            fill = .clear
        } else if cache.usesStatusColor {
            fill = Self.cellBase(intensity: intensity, usesStatusColor: true, unobserved: unobserved)
                .opacity(Self.cellOpacity(intensity: intensity, unobserved: unobserved))
        } else {
            fill = costFill(level: HistoryCalendarRules.costLevel(intensity: intensity))
        }
        return square(fill)
            .overlay {
                if day.date == cache.today {
                    RoundedRectangle(
                        cornerRadius: HistoryLayout.calendarCellRadius + HistoryLayout.todayRingWidth / 2,
                        style: .continuous
                    )
                    .stroke(.om(.text), lineWidth: HistoryLayout.todayRingWidth)
                    .padding(-HistoryLayout.todayRingWidth / 2)
                }
            }
            // The cache's own kind: the tooltip text came from it.
            .help(Self.cellTooltip(day.tooltip, hasReading: day.hasReading, isQuota: cache.usesStatusColor, caption: costCaption))
    }

    private func square(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: HistoryLayout.calendarCellRadius, style: .continuous)
            .fill(fill)
            .frame(width: cellSize, height: cellSize)
    }

    /// A cost square: the empty wash at step 0, then yolk at the step's strength.
    private func costFill(level: Int) -> Color {
        guard level > 0 else { return OMPalette.rgba(.calendarEmpty, scheme: colorScheme).color }
        return OMPalette.rgba(.accent, scheme: colorScheme).color
            .opacity(HistoryCalendarRules.levelOpacity(level))
    }

    private func legend(_ c: GridCache) -> some View {
        HStack(spacing: 6) {
            Text(c.legendLow)
            ForEach(HistoryCalendarRules.legendLevels, id: \.self) { level in
                square(legendFill(level: level, cache: c))
            }
            Text(c.legendHigh)
        }
        .font(.system(size: HistoryLayout.calendarLegendSize))
        .foregroundStyle(.om(.secondary))
    }

    private func legendFill(level: Int, cache c: GridCache) -> Color {
        guard c.usesStatusColor else { return costFill(level: level) }
        let intensity = Double(level) / 4
        return Self.cellBase(intensity: intensity, usesStatusColor: true, unobserved: false)
            .opacity(Self.cellOpacity(intensity: intensity, unobserved: false))
    }

    /// The colour a square is built from. Dollars have no "too much" level, so cost
    /// stays on one accent ramp; a quota square *is* a utilisation, so it gets the
    /// battery colours and a day that ran at 95 % reads red.
    nonisolated static func cellBase(intensity: Double, usesStatusColor: Bool, unobserved: Bool) -> Color {
        if unobserved { return .secondary }
        let clamped = max(0, min(1, intensity))
        if clamped == 0 { return .secondary }
        return usesStatusColor ? usageStatusColor(clamped * 100) : .accentColor
    }

    /// A ghost for a day nothing was recorded, the empty-square grey for an observed
    /// zero, and a 0.20 → 1.00 ramp for everything else.
    nonisolated static func cellOpacity(intensity: Double, unobserved: Bool) -> Double {
        if unobserved { return 0.05 }
        let clamped = max(0, min(1, intensity))
        if clamped == 0 { return 0.12 }
        return 0.20 + clamped * 0.80
    }

    /// The caption under the grid, or nil. Quota squares are percentages out of our own
    /// history, which no transcript cleanup can shorten, so the note belongs to the
    /// cost grid alone.
    nonisolated static func retentionNote(provider: String, showsQuota: Bool) -> String? {
        showsQuota ? nil : ActivityCopy.retentionNote(provider: provider)
    }

    /// Whether the selected provider's dollars are a bill, as the last poll saw it —
    /// the rule Overview and Insights use.
    private var costCaption: String? {
        CostCopy.apiEquivalentCaption(
            for: AppState.shared.snapshot.services.first(where: { $0.id == dashboard.selectedService })
        )
    }

    /// The line the 2.x stat cards carried: the API-equivalent caption when they were
    /// dollars on a subscription. History's header sentence says it now; the rule
    /// stays, pinned by its tests.
    nonisolated static func statsCaption(isQuota: Bool, caption: String?) -> String? {
        isQuota ? nil : caption
    }

    /// A square's tooltip. The tooltip is the one place the cost grid names a day's
    /// dollars, so a day with dollars gets the API-equivalent caption on a second line.
    /// A quota square, a day with nothing on it, a blank square (no tooltip at all)
    /// and a pay-as-you-go account (no caption) keep the tooltip as built.
    nonisolated static func cellTooltip(
        _ tooltip: String, hasReading: Bool, isQuota: Bool, caption: String?
    ) -> String {
        guard !isQuota, hasReading, !tooltip.isEmpty, let caption else { return tooltip }
        return "\(tooltip)\n\(caption)"
    }
}

// MARK: - Cache (computed off main thread, then cached in @State)

private struct TaskKey: Hashable {
    let range: TimeRange
    let service: String
    let cliUpdatedAt: Date
    let historyCount: Int
    let lastHistoryAt: Date
    let bucketIDs: [String]
    let day: Date
}

private struct Day: Sendable {
    let date: Date
    let value: Double
    /// Whether the source had anything to say about this day at all.
    let hasReading: Bool
    /// A square the grid draws empty and without a tooltip: after now, or before the
    /// range the grid covers began.
    let isBlank: Bool
    let tooltip: String
}

private struct MonthMarker: Sendable {
    let weekIndex: Int
    let label: String
}

struct GridStat: Sendable, Identifiable {
    let label: String
    let value: String
    let sub: String?
    var id: String { label }
}

/// One day's worth of whatever the grid is showing, already formatted.
private struct DayValue: Sendable {
    let value: Double
    let tooltip: String
}

struct GridCache: Sendable {
    fileprivate let weeksMatrix: [[Day]]
    /// The value a fully saturated square stands for. Cost fits the scale to the data
    /// (dollars have no ceiling); quota fixes it at 100% (it does, and rescaling would
    /// make a quiet week look like a busy one).
    let scaleMax: Double
    fileprivate let monthMarkers: [MonthMarker]
    let stats: [GridStat]
    let legendLow: String
    let legendHigh: String
    let dimsUnrecordedDays: Bool
    /// Whether the squares are a utilisation (battery colours) or dollars (accent ramp).
    let usesStatusColor: Bool
    let hasData: Bool
    /// The square to ring: the start of today in the calendar the cache was built with.
    let today: Date

    // MARK: Cost

    static func build(
        from dailies: [CLIDailySummary],
        weeks: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        notBefore: Date? = nil
    ) -> GridCache {
        let dailies = Self.dailiesByDay(dailies, calendar: calendar)
        let formatters = Formatters()
        var values: [Date: DayValue] = [:]
        for daily in dailies where daily.totalCost > 0 {
            let tooltip = String(format: "%@: $%.2f", formatters.date.string(from: daily.day), daily.totalCost)
            values[daily.day] = DayValue(value: daily.totalCost, tooltip: tooltip)
        }

        // Day starts, not "this time of day N days ago": a daily row is keyed by a day
        // start, so a cutoff mid-morning dropped the boundary day's whole total.
        let cutoffs = ActivityCardRule.cutoffs(now: now, calendar: calendar)
        var c30 = 0.0, c90 = 0.0, cy = 0.0, active = 0
        var maxCost = 0.0
        for d in dailies {
            if d.totalCost > maxCost { maxCost = d.totalCost }
            if d.day >= cutoffs.year && d.totalCost > 0 {
                cy += d.totalCost
                active += 1
            }
            if d.day >= cutoffs.ninety { c90 += d.totalCost }
            if d.day >= cutoffs.thirty { c30 += d.totalCost }
        }

        let layout = Layout(
            values: values, weeks: weeks, emptyTooltip: "no usage",
            formatters: formatters, now: now, calendar: calendar, notBefore: notBefore
        )
        return GridCache(
            weeksMatrix: layout.matrix,
            scaleMax: maxCost,
            monthMarkers: layout.markers,
            stats: [
                GridStat(label: "Last 30 days", value: String(format: "$%.2f", c30), sub: nil),
                GridStat(label: "Last 90 days", value: String(format: "$%.2f", c90), sub: nil),
                GridStat(label: "Last year", value: String(format: "$%.2f", cy), sub: "\(active) active days")
            ],
            legendLow: "Less",
            legendHigh: "More",
            dimsUnrecordedDays: false,
            usesStatusColor: false,
            hasData: !dailies.isEmpty,
            today: calendar.startOfDay(for: now)
        )
    }

    /// The rows re-keyed to the day of `calendar` each falls in, ascending, with rows
    /// that land on one date added together: `isDate(_:inSameDayAs:)`, spelled as a
    /// dictionary key. A folded day keeps the midnight of the zone it was binned in, and
    /// the grid walks this calendar's midnights — matched by `Date` equality, every such
    /// day went blank while the cards above still summed it.
    static func dailiesByDay(_ dailies: [CLIDailySummary], calendar: Calendar) -> [CLIDailySummary] {
        var byDay: [Date: CLIDailySummary] = [:]
        for daily in dailies {
            let day = calendar.startOfDay(for: daily.day)
            guard let kept = byDay[day] else {
                byDay[day] = CLIDailySummary(
                    day: day, totalCost: daily.totalCost, totalTokens: daily.totalTokens,
                    tokens: daily.tokens, turns: daily.turns, byFamily: daily.byFamily
                )
                continue
            }
            byDay[day] = CLIDailySummary(
                day: day,
                totalCost: kept.totalCost + daily.totalCost,
                totalTokens: kept.totalTokens + daily.totalTokens,
                tokens: kept.tokens + daily.tokens,
                turns: kept.turns + daily.turns,
                byFamily: kept.byFamily.merging(daily.byFamily, uniquingKeysWith: +)
            )
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// What the square for `day` shows: its value when a row landed on it, nil when no
    /// row did or the walk has no square for that date. `day` is a start of day in the
    /// calendar the cache was built with — the dates the view draws.
    func value(on day: Date) -> Double? {
        for column in weeksMatrix {
            for cell in column where cell.date == day {
                return cell.hasReading ? cell.value : nil
            }
        }
        return nil
    }

    // MARK: Quota

    static func build(
        records: [HistoryRecord],
        buckets: [QuotaBucketInfo],
        weeks: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        notBefore: Date? = nil
    ) -> GridCache {
        let formatters = Formatters()
        let coreIDs = buckets.filter(\.isCore).map(\.id)
        let labels = Dictionary(buckets.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let peaks = QuotaAnalytics.dailyPeaks(records: records, bucketIDs: coreIDs, calendar: calendar)

        var values: [Date: DayValue] = [:]
        for peak in peaks {
            let label = labels[peak.peakBucketID] ?? QuotaAnalytics.prettifiedLabel(for: peak.peakBucketID)
            let tooltip = String(
                format: "%@: peak %.0f%% (%@)",
                formatters.date.string(from: peak.day),
                peak.peak,
                label
            )
            values[peak.day] = DayValue(value: peak.peak, tooltip: tooltip)
        }

        let insights = QuotaAnalytics.insights(records: records, bucketIDs: coreIDs, calendar: calendar, now: now)
        let busiestSub = insights.busiestDay.map { day -> String in
            let label = labels[day.peakBucketID] ?? QuotaAnalytics.prettifiedLabel(for: day.peakBucketID)
            return "\(formatters.date.string(from: day.day)) · \(label)"
        }

        let layout = Layout(
            values: values, weeks: weeks, emptyTooltip: "not recorded",
            formatters: formatters, now: now, calendar: calendar, notBefore: notBefore
        )
        return GridCache(
            weeksMatrix: layout.matrix,
            scaleMax: 100,
            monthMarkers: layout.markers,
            stats: [
                GridStat(
                    label: "Days at capacity",
                    value: "\(insights.daysAtCapacity)",
                    sub: "of \(insights.daysObserved) recorded"
                ),
                GridStat(
                    label: "Average daily peak",
                    value: insights.averageDailyPeak.map { String(format: "%.0f%%", $0) } ?? "—",
                    sub: nil
                ),
                GridStat(
                    label: "Busiest day",
                    value: insights.busiestDay.map { String(format: "%.0f%%", $0.peak) } ?? "—",
                    sub: busiestSub
                )
            ],
            legendLow: "0%",
            legendHigh: "100%",
            dimsUnrecordedDays: true,
            usesStatusColor: true,
            hasData: !peaks.isEmpty,
            today: calendar.startOfDay(for: now)
        )
    }

    // MARK: Shared layout

    /// `DateFormatter` is expensive to build and both builders need the same two.
    private struct Formatters {
        let date: DateFormatter
        let month: DateFormatter

        init() {
            let d = DateFormatter()
            d.dateStyle = .medium
            self.date = d
            let m = DateFormatter()
            m.dateFormat = "MMM"
            self.month = m
        }
    }

    /// The calendar walk both metrics share: `weeks` columns of seven days ending in
    /// the current week, plus the month labels above them.
    private struct Layout {
        let matrix: [[Day]]
        let markers: [MonthMarker]

        init(
            values: [Date: DayValue],
            weeks: Int,
            emptyTooltip: String,
            formatters: Formatters,
            now: Date,
            calendar cal: Calendar,
            notBefore: Date?
        ) {
            let today = cal.startOfDay(for: now)
            let startOfThisWeek = GridCache.weekStart(of: today, calendar: cal)

            var matrix: [[Day]] = []
            matrix.reserveCapacity(weeks)
            var markers: [MonthMarker] = []
            var lastMonth = -1

            for w in 0..<weeks {
                var column: [Day] = []
                column.reserveCapacity(7)
                for d in 0..<7 {
                    let offset = -(weeks - 1 - w) * 7 + d
                    let date = cal.date(byAdding: .day, value: offset, to: startOfThisWeek) ?? today
                    let isBlank = date > now || notBefore.map { date < $0 } == true
                    let entry = isBlank ? nil : values[date]
                    let tooltip: String
                    if isBlank {
                        tooltip = ""
                    } else if let entry {
                        tooltip = entry.tooltip
                    } else {
                        tooltip = "\(formatters.date.string(from: date)): \(emptyTooltip)"
                    }
                    column.append(Day(
                        date: date,
                        value: entry?.value ?? 0,
                        hasReading: entry != nil,
                        isBlank: isBlank,
                        tooltip: tooltip
                    ))
                }
                matrix.append(column)
                if w > 0, let first = column.first {
                    let day = cal.component(.day, from: first.date)
                    let month = cal.component(.month, from: first.date)
                    if day <= 7 && month != lastMonth {
                        markers.append(MonthMarker(weekIndex: w, label: formatters.month.string(from: first.date)))
                        lastMonth = month
                    }
                }
            }

            self.matrix = matrix
            self.markers = markers
        }
    }
}

// MARK: - Weeks

extension GridCache {
    /// The first day of the week `date` falls in, weeks starting on the calendar's own
    /// first weekday (Monday in most of Europe, Sunday in the US): the column the grid
    /// puts that day in.
    static func weekStart(of date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    /// The row names, top to bottom in the order the calendar's week runs: Monday,
    /// Wednesday and Friday named in its language, the other rows blank.
    static func weekdayLabels(calendar: Calendar) -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { row in
            let weekday = (calendar.firstWeekday - 1 + row) % 7 + 1
            return [2, 4, 6].contains(weekday) ? symbols[weekday - 1] : ""
        }
    }
}
