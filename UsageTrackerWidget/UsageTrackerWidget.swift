import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Provider selection intent

enum ProviderChoice: String, AppEnum {
    case claude
    case codex
    case gemini
    case antigravity
    case grok

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .claude: "Claude",
        .codex: "Codex (OpenAI)",
        .gemini: "Gemini",
        .antigravity: "Antigravity",
        .grok: "Grok",
    ]

    var fallbackName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        }
    }

    var fallbackIcon: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .antigravity: return "circle.grid.cross"
        case .grok: return "x.circle"
        }
    }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Choose which provider this widget tracks.")

    @Parameter(title: "Provider", default: .claude)
    var provider: ProviderChoice
}

// MARK: - Timelines

struct ProviderEntry: TimelineEntry {
    let date: Date
    let provider: ProviderChoice
    let service: WidgetService?
    let updatedAt: Date
}

private func timelineEntries<E>(now: Date, make: (Date) -> E) -> Timeline<E> {
    // Emit a few entries spaced 1 minute apart so "Updated Xm ago" text refreshes
    // even if the main app hasn't fetched new data yet; then ask for a new timeline
    // (the app's reloadAllTimelines() also triggers one whenever it polls).
    let entries = (0..<6).map { make(now.addingTimeInterval(Double($0) * 60)) }
    return Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 60)))
}

struct ProviderTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProviderEntry {
        let snap = WidgetSnapshot.placeholder
        return ProviderEntry(date: Date(), provider: .claude, service: snap.service(id: "claude"), updatedAt: snap.updatedAt)
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> ProviderEntry {
        entry(for: configuration.provider, at: Date())
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        timelineEntries(now: Date()) { entry(for: configuration.provider, at: $0) }
    }

    private func entry(for provider: ProviderChoice, at date: Date) -> ProviderEntry {
        let snap = SharedWidgetStore.read() ?? .placeholder
        return ProviderEntry(
            date: date,
            provider: provider,
            service: snap.service(id: provider.rawValue),
            updatedAt: snap.updatedAt
        )
    }
}

struct AllProvidersEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct AllProvidersTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllProvidersEntry {
        AllProvidersEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AllProvidersEntry) -> Void) {
        completion(AllProvidersEntry(date: Date(), snapshot: SharedWidgetStore.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AllProvidersEntry>) -> Void) {
        let snap = SharedWidgetStore.read() ?? .placeholder
        completion(timelineEntries(now: Date()) { AllProvidersEntry(date: $0, snapshot: snap) })
    }
}

// MARK: - Widget definitions

@main
struct UsageTrackerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProviderWidget()
        AllProvidersWidget()
    }
}

/// Per-provider widget (the original kind, so existing placements keep working —
/// they default to Claude, which is exactly what they showed before).
struct ProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: SharedWidgetStore.providerWidgetKind,
            intent: SelectProviderIntent.self,
            provider: ProviderTimelineProvider()
        ) { entry in
            ProviderWidgetEntryView(entry: entry)
                .containerBackground(.regularMaterial, for: .widget)
        }
        .configurationDisplayName("Provider usage")
        .description("Limits for one provider — right-click the widget to pick which.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Overview widget: every connected provider at a glance.
struct AllProvidersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SharedWidgetStore.allProvidersWidgetKind,
            provider: AllProvidersTimelineProvider()
        ) { entry in
            AllProvidersWidgetView(snapshot: entry.snapshot)
                .containerBackground(.regularMaterial, for: .widget)
        }
        .configurationDisplayName("All providers")
        .description("Every connected provider's limits at a glance.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Per-provider entry view

struct ProviderWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProviderEntry

    var body: some View {
        if let service = entry.service {
            switch family {
            case .systemSmall: SmallProviderView(service: service)
            case .systemMedium: MediumProviderView(service: service, updatedAt: entry.updatedAt)
            case .systemLarge: LargeProviderView(service: service, updatedAt: entry.updatedAt)
            default: SmallProviderView(service: service)
            }
        } else {
            NoDataView(provider: entry.provider)
        }
    }
}

/// Shown when the selected provider has published no usage (signed out / not running).
struct NoDataView: View {
    let provider: ProviderChoice

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: provider.fallbackIcon)
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(provider.fallbackName)
                .font(.system(size: 12, weight: .semibold))
            Text("No data")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small (158×158)

struct SmallProviderView: View {
    let service: WidgetService

    var body: some View {
        ZStack {
            ringBar
            VStack(spacing: 0) {
                Text(service.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(Int((service.headlineBucket?.percent ?? 0).rounded()))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if let label = service.headlineBucket?.label {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
        }
    }

    private var ringBar: some View {
        let percent = service.headlineBucket?.percent ?? 0
        return Circle()
            .trim(from: 0, to: 1)
            .stroke(.quaternary, lineWidth: 10)
            .overlay(
                Circle()
                    .trim(from: 0, to: max(0.005, percent / 100))
                    .stroke(
                        statusColor(percent),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            )
            .padding(8)
    }
}

// MARK: - Medium (338×158)

struct MediumProviderView: View {
    let service: WidgetService
    let updatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ServiceHeader(service: service, updatedAt: updatedAt)
            ForEach(displayBuckets) { bucket in
                WidgetBucketRow(bucket: bucket)
            }
        }
        .padding(14)
    }

    /// Two rows fit: the session window plus the busiest other window.
    private var displayBuckets: [WidgetBucket] {
        var rows: [WidgetBucket] = []
        if let session = service.sessionBuckets.first { rows.append(session) }
        rows.append(contentsOf: service.nonSessionBuckets
            .sorted { $0.percent > $1.percent }
            .prefix(2 - rows.count))
        return rows
    }
}

// MARK: - Large per-provider (338×354)

struct LargeProviderView: View {
    let service: WidgetService
    let updatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ServiceHeader(service: service, updatedAt: nil)
            Divider()
            ForEach(service.sessionBuckets.prefix(2)) { bucket in
                WidgetBucketRow(bucket: bucket)
            }
            ForEach(service.nonSessionBuckets.prefix(5)) { bucket in
                WidgetBucketRow(bucket: bucket)
            }
            Spacer()
            Text("Updated \(WidgetTime.ago(updatedAt))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }
}

// MARK: - All providers (large)

struct AllProvidersWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.services.prefix(4)) { service in
                VStack(alignment: .leading, spacing: 6) {
                    ServiceHeader(service: service, updatedAt: nil)
                    // The worst two windows tell the story; details live in the app.
                    ForEach(topBuckets(of: service)) { bucket in
                        WidgetBucketRow(bucket: bucket, compact: true)
                    }
                }
                if service.id != snapshot.services.prefix(4).last?.id {
                    Divider()
                }
            }
            Spacer()
            Text("Updated \(WidgetTime.ago(snapshot.updatedAt))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func topBuckets(of service: WidgetService) -> [WidgetBucket] {
        var rows: [WidgetBucket] = []
        if let session = service.sessionBuckets.first { rows.append(session) }
        rows.append(contentsOf: service.nonSessionBuckets
            .sorted { $0.percent > $1.percent }
            .prefix(2 - rows.count))
        return rows
    }
}

// MARK: - Shared pieces

struct ServiceHeader: View {
    let service: WidgetService
    let updatedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: service.icon)
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text(service.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            if let plan = service.plan {
                Text(plan)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let updatedAt {
                Text("Updated \(WidgetTime.ago(updatedAt))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct WidgetBucketRow: View {
    let bucket: WidgetBucket
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack {
                Text(bucket.label)
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(bucket.percent.rounded()))%")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let resets = bucket.resetsAt {
                    Text(WidgetTime.until(resets))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            ProgressBar(percent: bucket.percent, height: compact ? 5 : 6)
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

#Preview("All providers") {
    AllProvidersWidgetView(snapshot: .placeholder)
        .frame(width: 338, height: 354)
        .background(.regularMaterial)
}

#Preview("Small") {
    SmallProviderView(service: WidgetSnapshot.placeholder.services[0])
        .frame(width: 158, height: 158)
        .background(.regularMaterial)
}
