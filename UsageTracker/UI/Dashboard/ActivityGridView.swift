import SwiftUI

struct ActivityGridView: View {
    @ObservedObject var dashboard: DashboardState

    @State private var weeks: Int = 52
    @State private var cache: GridCache?

    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 3

    /// Providers with no local cost log get a grid of daily *quota* peaks instead of a
    /// dead end — for a subscription that is the same story in the only unit available.
    private var showsQuota: Bool { !dashboard.costSource.hasBreakdown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DashboardHeader(
                    title: "Activity",
                    subtitle: subtitle,
                    trailing: AnyView(rangePicker)
                )

                if showsQuota, cache?.hasData == false {
                    noQuotaPlaceholder
                } else if let cache {
                    statCards(cache)
                        .padding(.horizontal, 24)
                    // The cache's own kind, like the tooltips: the cards' figures came from it.
                    if let caption = Self.statsCaption(isQuota: cache.usesStatusColor, caption: costCaption) {
                        Text(caption)
                            .font(OMFont.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                    }
                    if let note = Self.retentionNote(
                        provider: dashboard.selectedService, showsQuota: showsQuota
                    ) {
                        Text(note)
                            .font(OMFont.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                    }
                    gridBlock(cache)
                        .padding(.horizontal, 24)
                    if showsQuota { costFootnote }
                } else {
                    placeholder
                }

                Spacer(minLength: 24)
            }
        }
        .task(id: taskKey) {
            await rebuildCache()
        }
    }

    private var subtitle: String {
        if showsQuota { return "Daily peak quota use" }
        return dashboard.costSource.shortName.map { "Daily cost (\($0))" } ?? "Daily cost"
    }

    private var taskKey: TaskKey {
        TaskKey(
            weeks: weeks,
            service: dashboard.selectedService,
            cliUpdatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast,
            historyCount: dashboard.history.count,
            lastHistoryAt: dashboard.history.last?.timestamp ?? .distantPast,
            bucketIDs: dashboard.quotaBuckets.map(\.id)
        )
    }

    @MainActor
    private func rebuildCache() async {
        let started = taskKey
        let weeksCopy = weeks
        // Heavy work off the main actor, whichever metric the grid is showing.
        let built: GridCache
        if showsQuota {
            let records = dashboard.history
            let buckets = dashboard.quotaBuckets
            built = await Task.detached(priority: .userInitiated) {
                GridCache.build(records: records, buckets: buckets, weeks: weeksCopy)
            }.value
        } else {
            let dailies = dashboard.cliBreakdown?.daily ?? []
            built = await Task.detached(priority: .userInitiated) {
                GridCache.build(from: dailies, weeks: weeksCopy)
            }.value
        }
        // See `DerivedCacheGate`: the await does not stop when `.task(id:)` cancels this
        // pass, and a slow pass for the provider or range just left would land last.
        guard DerivedCacheGate.canPublish(
            started: started, current: taskKey, cancelled: Task.isCancelled
        ) else { return }
        cache = built
    }

    private var rangePicker: some View {
        Picker("", selection: $weeks) {
            Text("13w").tag(13)
            Text("26w").tag(26)
            Text("52w").tag(52)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading activity…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// Quota history only starts when the app first polls this provider successfully,
    /// so a fresh provider has an honest reason for an empty grid.
    private var noQuotaPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No quota recorded yet for \(dashboard.displayName(for: dashboard.selectedService))")
                .foregroundStyle(.secondary)
            Text("Each successful poll records this provider's windows; the grid fills in from there.")
                .font(OMFont.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// Squares here are percentages, not dollars. Say so, so their absence doesn't
    /// read as a bug.
    private var costFootnote: some View {
        Text(dashboard.costSource.reason ?? "")
            .font(OMFont.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
    }

    private func statCards(_ c: GridCache) -> some View {
        HStack(spacing: 12) {
            ForEach(c.stats) { stat in
                statCard(stat)
            }
        }
    }

    private func statCard(_ stat: GridStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.label).font(OMFont.caption).foregroundStyle(.secondary)
            Text(stat.value)
                .font(OMFont.heroNumeral)
                .monospacedDigit()
            if let sub = stat.sub {
                Text(sub).font(OMFont.caption).foregroundStyle(.tertiary)
            }
        }
        .dashboardCard(padding: 12)
    }

    private func gridBlock(_ c: GridCache) -> some View {
        let gridWidth = CGFloat(c.weeksMatrix.count) * (cellSize + spacing) + 32
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    monthLabels(c, width: gridWidth)
                    HStack(alignment: .top, spacing: spacing) {
                        weekdayLabels
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
            legend(c).padding(.top, 8)
        }
        .dashboardCard(padding: 14)
    }

    private func monthLabels(_ c: GridCache, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 28)
            ZStack(alignment: .leading) {
                ForEach(c.monthMarkers, id: \.weekIndex) { marker in
                    Text(marker.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(marker.weekIndex) * (cellSize + spacing))
                }
            }
            .frame(width: width - 28, alignment: .leading)
            .frame(height: 12)
        }
    }

    private var weekdayLabels: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<7, id: \.self) { d in
                let labels = ["", "Mon", "", "Wed", "", "Fri", ""]
                Text(labels[d])
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: cellSize, alignment: .trailing)
                    .padding(.trailing, 4)
            }
        }
    }

    private func cell(_ day: Day, cache: GridCache) -> some View {
        let intensity = cache.scaleMax > 0 ? min(1.0, day.value / cache.scaleMax) : 0
        // A day the app never observed is not a day of no usage. Only the quota grid
        // can tell the two apart, so only it draws the difference.
        let unobserved = cache.dimsUnrecordedDays && !day.hasReading
        return RoundedRectangle(cornerRadius: 3)
            .fill(day.isFuture
                  ? Color.clear
                  : Self.cellBase(intensity: intensity, usesStatusColor: cache.usesStatusColor, unobserved: unobserved)
                      .opacity(Self.cellOpacity(intensity: intensity, unobserved: unobserved)))
            .frame(width: cellSize, height: cellSize)
            // The cache's own kind, not the picker's: the tooltip text came from it.
            .help(Self.cellTooltip(day.tooltip, hasReading: day.hasReading, isQuota: cache.usesStatusColor, caption: costCaption))
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

    /// The caption under the stats row, or nil. Quota squares are percentages out of
    /// our own history, which no transcript cleanup can shorten, so the note belongs
    /// to the cost grid alone.
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

    /// The line under the 30/90/365-day cards: the API-equivalent caption when they
    /// are dollars on a subscription. The quota grid's cards are percentages, and a
    /// pay-as-you-go account's dollars are the bill (nil caption); both get no line.
    nonisolated static func statsCaption(isQuota: Bool, caption: String?) -> String? {
        isQuota ? nil : caption
    }

    /// A square's tooltip. The tooltip is the one place the cost grid names a day's
    /// dollars, so a day with dollars gets the API-equivalent caption on a second line.
    /// A quota square, a day with nothing on it, a future square (no tooltip at all)
    /// and a pay-as-you-go account (no caption) keep the tooltip as built.
    nonisolated static func cellTooltip(
        _ tooltip: String, hasReading: Bool, isQuota: Bool, caption: String?
    ) -> String {
        guard !isQuota, hasReading, !tooltip.isEmpty, let caption else { return tooltip }
        return "\(tooltip)\n\(caption)"
    }

    private func legend(_ c: GridCache) -> some View {
        HStack(spacing: 6) {
            Text(c.legendLow).font(OMFont.caption).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { i in
                let intensity = Double(i) / 4.0
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.cellBase(intensity: intensity, usesStatusColor: c.usesStatusColor, unobserved: false)
                        .opacity(Self.cellOpacity(intensity: intensity, unobserved: false)))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(c.legendHigh).font(OMFont.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cache (computed off main thread, then cached in @State)

private struct TaskKey: Hashable {
    let weeks: Int
    let service: String
    let cliUpdatedAt: Date
    let historyCount: Int
    let lastHistoryAt: Date
    let bucketIDs: [String]
}

private struct Day: Sendable {
    let date: Date
    let value: Double
    /// Whether the source had anything to say about this day at all.
    let hasReading: Bool
    let isFuture: Bool
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

    // MARK: Cost

    static func build(
        from dailies: [CLIDailySummary],
        weeks: Int,
        now: Date = Date(),
        calendar: Calendar = .current
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
            formatters: formatters, now: now, calendar: calendar
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
            hasData: !dailies.isEmpty
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

    static func build(records: [HistoryRecord], buckets: [QuotaBucketInfo], weeks: Int) -> GridCache {
        let formatters = Formatters()
        let coreIDs = buckets.filter(\.isCore).map(\.id)
        let labels = Dictionary(buckets.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let peaks = QuotaAnalytics.dailyPeaks(records: records, bucketIDs: coreIDs)

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

        let insights = QuotaAnalytics.insights(records: records, bucketIDs: coreIDs)
        let busiestSub = insights.busiestDay.map { day -> String in
            let label = labels[day.peakBucketID] ?? QuotaAnalytics.prettifiedLabel(for: day.peakBucketID)
            return "\(formatters.date.string(from: day.day)) · \(label)"
        }

        let layout = Layout(
            values: values, weeks: weeks, emptyTooltip: "not recorded",
            formatters: formatters, now: Date(), calendar: .current
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
            hasData: !peaks.isEmpty
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
            calendar cal: Calendar
        ) {
            let today = cal.startOfDay(for: now)
            let weekday = cal.component(.weekday, from: today) - 1
            let startOfThisWeek = cal.date(byAdding: .day, value: -weekday, to: today) ?? today

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
                    let entry = values[date]
                    let isFuture = date > now
                    let tooltip: String
                    if isFuture {
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
                        isFuture: isFuture,
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
