import SwiftUI

struct ActivityGridView: View {
    @ObservedObject var dashboard: DashboardState

    @State private var weeks: Int = 52
    @State private var cache: GridCache?

    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DashboardHeader(
                    title: "Activity",
                    subtitle: "Daily cost (Claude Code CLI)",
                    trailing: AnyView(rangePicker)
                )

                if let cache {
                    statCards(cache)
                        .padding(.horizontal, 24)
                    gridBlock(cache)
                        .padding(.horizontal, 24)
                } else {
                    placeholder
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: TaskKey(weeks: weeks, cliUpdatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast)) {
            await rebuildCache()
        }
    }

    @MainActor
    private func rebuildCache() async {
        let dailies = dashboard.cliBreakdown?.daily ?? []
        let weeksCopy = weeks
        // Heavy work off the main actor
        let built: GridCache = await Task.detached(priority: .userInitiated) {
            GridCache.build(from: dailies, weeks: weeksCopy)
        }.value
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

    private func statCards(_ c: GridCache) -> some View {
        HStack(spacing: 12) {
            statCard(label: "Last 30 days", value: c.cost30)
            statCard(label: "Last 90 days", value: c.cost90)
            statCard(label: "Last year", value: c.costYear, sub: "\(c.activeDaysYear) active days")
        }
    }

    private func statCard(label: String, value: Double, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(String(format: "$%.2f", value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let sub {
                Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
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
                                    cell(c.weeksMatrix[w][d], maxCost: c.maxCost)
                                }
                            }
                        }
                    }
                }
            }
            legend.padding(.top, 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func cell(_ day: Day, maxCost: Double) -> some View {
        let intensity = maxCost > 0 ? min(1.0, day.cost / maxCost) : 0
        let isFuture = day.isFuture
        return RoundedRectangle(cornerRadius: 3)
            .fill(isFuture ? Color.clear : color(for: intensity))
            .frame(width: cellSize, height: cellSize)
            .help(day.tooltip)
    }

    private func color(for intensity: Double) -> Color {
        if intensity == 0 { return Color.secondary.opacity(0.12) }
        return Color.accentColor.opacity(0.20 + intensity * 0.80)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: Double(i) / 4.0))
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cache (computed off main thread, then cached in @State)

private struct TaskKey: Hashable {
    let weeks: Int
    let cliUpdatedAt: Date
}

private struct Day: Sendable {
    let date: Date
    let cost: Double
    let isFuture: Bool
    let tooltip: String
}

private struct MonthMarker: Sendable {
    let weekIndex: Int
    let label: String
}

private struct GridCache: Sendable {
    let weeksMatrix: [[Day]]
    let maxCost: Double
    let monthMarkers: [MonthMarker]
    let cost30: Double
    let cost90: Double
    let costYear: Double
    let activeDaysYear: Int

    static func build(from dailies: [CLIDailySummary], weeks: Int) -> GridCache {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today) - 1
        let startOfThisWeek = cal.date(byAdding: .day, value: -weekday, to: today) ?? today

        let costMap = Dictionary(dailies.map { ($0.day, $0.totalCost) }, uniquingKeysWith: +)

        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            return f
        }()
        let monthFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM"
            return f
        }()

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
                let cost = costMap[date] ?? 0
                let isFuture = date > now
                let tooltip: String
                if isFuture {
                    tooltip = ""
                } else if cost == 0 {
                    tooltip = "\(dateFormatter.string(from: date)): no usage"
                } else {
                    tooltip = String(format: "%@: $%.2f", dateFormatter.string(from: date), cost)
                }
                column.append(Day(date: date, cost: cost, isFuture: isFuture, tooltip: tooltip))
            }
            matrix.append(column)
            if w > 0, let first = column.first {
                let day = cal.component(.day, from: first.date)
                let month = cal.component(.month, from: first.date)
                if day <= 7 && month != lastMonth {
                    markers.append(MonthMarker(weekIndex: w, label: monthFormatter.string(from: first.date)))
                    lastMonth = month
                }
            }
        }

        let cutoff30 = now.addingTimeInterval(-30 * 24 * 3600)
        let cutoff90 = now.addingTimeInterval(-90 * 24 * 3600)
        let cutoffYear = now.addingTimeInterval(-365 * 24 * 3600)
        var c30 = 0.0, c90 = 0.0, cy = 0.0, active = 0
        var max = 0.0
        for d in dailies {
            if d.totalCost > max { max = d.totalCost }
            if d.day >= cutoffYear && d.totalCost > 0 {
                cy += d.totalCost
                active += 1
            }
            if d.day >= cutoff90 { c90 += d.totalCost }
            if d.day >= cutoff30 { c30 += d.totalCost }
        }

        return GridCache(
            weeksMatrix: matrix,
            maxCost: max,
            monthMarkers: markers,
            cost30: c30,
            cost90: c90,
            costYear: cy,
            activeDaysYear: active
        )
    }
}
