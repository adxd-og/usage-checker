import SwiftUI

/// Provider-tab header: the hero window as a large ring next to its name,
/// time to reset, the status phrase, and the burn verdict when there is one.
struct OMHero: View {
    let hero: UsageBucket
    var verdict: BurnVerdict? = nil

    /// `View` is @MainActor; the phrase is pure, so it stays callable anywhere.
    nonisolated static func statusPhrase(_ percent: Double) -> String {
        if percent >= 90 { return "Almost at the limit" }
        if percent >= 70 { return "Running hot" }
        if percent >= 50 { return "On track" }
        return "Plenty of headroom"
    }

    var body: some View {
        HStack(spacing: 14) {
            OMRing(percent: hero.clampedPercent, size: .hero, pace: hero.elapsedFraction())
            VStack(alignment: .leading, spacing: 3) {
                Text(hero.label).font(.system(size: 14, weight: .semibold))
                if let remaining = WindowRanking.remainingText(until: hero.resetsAt) {
                    Text(remaining).font(OMFont.caption).foregroundStyle(.secondary)
                        .help("Resets \(hero.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                }
                Text(Self.statusPhrase(hero.clampedPercent))
                    .font(OMFont.caption.weight(.semibold))
                    .foregroundStyle(usageStatusColor(hero.clampedPercent))
                if let verdict {
                    HStack(spacing: 5) {
                        Image(systemName: verdict.willHit ? "flame.fill" : "checkmark.circle")
                            .font(.caption2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(verdict.willHit ? Color.orange : Color.secondary)
                        Text(verdict.text)
                            .font(.caption2)
                            .foregroundStyle(verdict.willHit ? Color.primary : Color.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, OMSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hero.label), \(Int(hero.clampedPercent.rounded())) percent used, \(Self.statusPhrase(hero.clampedPercent))")
    }
}

#Preview("Hero") {
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 37, resetsAt: Date().addingTimeInterval(8100), kind: .session)
    return OMHero(hero: session, verdict: BurnVerdict(willHit: true, text: "At this pace, limit in ~1h 40m"))
        .padding().frame(width: 328)
}
