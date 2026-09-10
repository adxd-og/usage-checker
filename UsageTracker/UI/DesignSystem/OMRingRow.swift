import SwiftUI

/// Weekly / model-scoped windows as a grid of small rings. Four per row; an
/// untouched window keeps its ring (so the grid stays aligned) but dims.
struct OMRingRow: View {
    let buckets: [UsageBucket]
    let mode: PercentDisplay.Mode

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OMSpacing.s), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: OMSpacing.m) {
            ForEach(buckets) { bucket in
                VStack(spacing: 5) {
                    OMRing(used: bucket.clampedPercent, mode: mode, size: .small, pace: bucket.elapsedFraction())
                    Text(WindowRanking.shortWindowLabel(bucket.label))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(bucket.clampedPercent == 0 ? 0.55 : 1)
                // Two different readers, two different needs: the tooltip answers
                // "when exactly?" for someone already looking at the ring, while
                // VoiceOver keeps the full date because a screen reader cannot
                // glance at a calendar to place "Thu 14:15".
                .help(Self.tooltip(for: bucket))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.accessibilityLabel(for: bucket, mode: mode))
            }
        }
    }

    /// "All models · resets Thu 14:15" — the absolute form, always.
    nonisolated static func tooltip(
        for bucket: UsageBucket,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let title = bucket.clampedPercent == 0 ? emptyHint(for: bucket) : bucket.label
        guard let absolute = ResetCopy.absolute(resetsAt: bucket.resetsAt, now: now, calendar: calendar, locale: locale)
        else { return title }
        return "\(title) · resets \(absolute)"
    }

    /// What VoiceOver reads — unchanged: the abbreviated date and time.
    nonisolated static func accessibilityText(for bucket: UsageBucket) -> String {
        let title = bucket.clampedPercent == 0 ? emptyHint(for: bucket) : bucket.label
        if bucket.resetsAt < .distantFuture {
            return "\(title) · resets \(bucket.resetsAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return title
    }

    /// The whole spoken line for one ring: the window (or the hint that explains an
    /// empty one), then the number. Which of the two titles it gets is decided on
    /// the used value, so a window nobody has touched never reads as a full tank.
    nonisolated static func accessibilityLabel(for bucket: UsageBucket, mode: PercentDisplay.Mode) -> String {
        "\(accessibilityText(for: bucket)), \(PercentDisplay.spoken(bucket.clampedPercent, mode: mode))"
    }

    /// An untouched window can't say anything about pace, so its label explains the
    /// empty ring instead of repeating itself.
    nonisolated static func emptyHint(for bucket: UsageBucket) -> String {
        if bucket.id == "seven_day_oauth_apps" { return "No OAuth apps yet" }
        guard bucket.kind == .modelSpecific else { return bucket.label }
        // "Opus only" → "You haven't used Opus yet"; works for any bucket label.
        var name = bucket.label
        if name.hasSuffix(" only") { name.removeLast(" only".count) }
        return "You haven't used \(name) yet"
    }
}

#Preview("Ring row") {
    let mk = { (id: String, label: String, p: Double) in
        UsageBucket(id: id, label: label, utilization: p, resetsAt: Date().addingTimeInterval(86400 * 3), kind: .weekly)
    }
    return OMRingRow(buckets: [mk("seven_day", "All models", 52), mk("seven_day_fable", "Fable only", 12), mk("seven_day_opus", "Opus only", 8), mk("seven_day_sonnet", "Sonnet only", 74), mk("seven_day_haiku", "Haiku only", 0)], mode: .used)
        .padding().frame(width: 328)
}
