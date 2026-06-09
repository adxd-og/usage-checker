import WidgetKit
import SwiftUI

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPlaceholder: Bool
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snap = SharedWidgetStore.read() ?? .placeholder
        completion(UsageEntry(date: Date(), snapshot: snap, isPlaceholder: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let snap = SharedWidgetStore.read() ?? .placeholder
        // Emit a few entries spaced 1 minute apart so the "Updated Xm ago" text refreshes
        // even if the main app hasn't fetched new data yet. Each carries the same snapshot.
        var entries: [UsageEntry] = []
        for offset in 0..<6 {
            let date = now.addingTimeInterval(Double(offset) * 60)
            entries.append(UsageEntry(date: date, snapshot: snap, isPlaceholder: false))
        }
        // After 6 minutes ask WidgetKit to fetch a new timeline (which will read the shared
        // file again — main app's reloadAllTimelines() also triggers this whenever it polls).
        let next = now.addingTimeInterval(6 * 60)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

// MARK: - Widget definition

@main
struct UsageTrackerWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageTrackerWidget()
    }
}

struct UsageTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetStore.widgetKind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(.regularMaterial, for: .widget)
        }
        .configurationDisplayName("Claude usage")
        .description("Track your Claude subscription limits at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry view

struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(snapshot: entry.snapshot)
        case .systemMedium: MediumWidgetView(snapshot: entry.snapshot)
        case .systemLarge: LargeWidgetView(snapshot: entry.snapshot)
        default: SmallWidgetView(snapshot: entry.snapshot)
        }
    }
}

// MARK: - Small (158×158)

struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack {
            ringBar
            VStack(spacing: 0) {
                Text("5h")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(snapshot.headlineLabel)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ringBar: some View {
        let p = (snapshot.fiveHourPercent ?? 0) / 100
        return Circle()
            .trim(from: 0, to: 1)
            .stroke(.quaternary, lineWidth: 10)
            .overlay(
                Circle()
                    .trim(from: 0, to: max(0.005, p))
                    .stroke(
                        statusColor(snapshot.fiveHourPercent ?? 0),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            )
            .padding(8)
    }
}

// MARK: - Medium (338×158)

struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("Claude").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                if let plan = snapshot.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Updated \(WidgetTime.ago(snapshot.updatedAt))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            row(label: "5h session", percent: snapshot.fiveHourPercent, resets: snapshot.fiveHourResetsAt)
            row(label: "7d weekly", percent: snapshot.sevenDayPercent, resets: snapshot.sevenDayResetsAt)
        }
        .padding(14)
    }

    private func row(label: String, percent: Double?, resets: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let p = percent {
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                if let r = resets, r < .distantFuture {
                    Text(WidgetTime.until(r)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            ProgressBar(percent: percent ?? 0)
        }
    }
}

// MARK: - Large (338×354)

struct LargeWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("Claude").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                if let plan = snapshot.plan {
                    Text(plan).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            sectionTitle("Current session")
            row(label: "5-hour window", percent: snapshot.fiveHourPercent, resets: snapshot.fiveHourResetsAt)

            sectionTitle("Weekly limits")
            row(label: "All models", percent: snapshot.sevenDayPercent, resets: snapshot.sevenDayResetsAt)
            // The large widget fits ~4 extra rows below the fixed ones.
            ForEach(snapshot.weeklyModelBuckets.prefix(4)) { bucket in
                row(label: bucket.label, percent: bucket.percent, resets: nil)
            }

            Spacer()
            Text("Updated \(WidgetTime.ago(snapshot.updatedAt))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func row(label: String, percent: Double?, resets: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.primary)
                Spacer()
                if let p = percent {
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            ProgressBar(percent: percent ?? 0)
        }
    }
}

// MARK: - Helpers

enum WidgetTime {
    static func ago(_ date: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(date))
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(Int(delta)) sec ago" }
        if delta < 3600 {
            let m = Int(delta / 60)
            return "\(m) min ago"
        }
        if delta < 24 * 3600 {
            let h = Int(delta / 3600)
            return "\(h)h ago"
        }
        let d = Int(delta / (24 * 3600))
        return "\(d)d ago"
    }

    static func until(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        if delta < 3600 { return "in \(Int(delta / 60))m" }
        if delta < 24 * 3600 {
            let h = Int(delta / 3600)
            return "in \(h)h"
        }
        let d = Int(delta / (24 * 3600))
        return "in \(d)d"
    }
}

struct ProgressBar: View {
    let percent: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(statusColor(percent))
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, percent)) / 100))
            }
        }
        .frame(height: height)
    }
}

/// Battery-style status color, mirrors the main app's usageStatusColor.
func statusColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .accentColor
}

#Preview("Large") {
    LargeWidgetView(snapshot: .placeholder)
        .frame(width: 338, height: 354)
        .background(.regularMaterial)
}

#Preview("Small") {
    SmallWidgetView(snapshot: .placeholder)
        .frame(width: 158, height: 158)
        .background(.regularMaterial)
}
