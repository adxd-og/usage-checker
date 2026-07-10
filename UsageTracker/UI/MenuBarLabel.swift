import SwiftUI

struct MenuBarLabel: View {
    let snapshot: UsageSnapshot

    private var displayServices: [ServiceSnapshot] {
        // A service earns a pill with rate windows OR (pay-as-you-go) a $ figure.
        snapshot.services.filter { !$0.buckets.isEmpty || $0.weekCost != nil }
    }

    var body: some View {
        HStack(spacing: 4) {
            if displayServices.isEmpty {
                Image(systemName: "chart.bar")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayServices) { service in
                    if service.buckets.isEmpty, let cost = service.weekCost {
                        MiniCostPill(service: service, weekCost: cost, isStale: snapshot.isStale)
                    } else {
                        MiniServiceBar(service: service, isStale: snapshot.isStale)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 18)
        .opacity(snapshot.isStale ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.45), value: snapshot.headlinePercent)
    }
}

/// Pay-as-you-go pill: no rate windows to show, so the 7-day local spend is the number.
private struct MiniCostPill: View {
    let service: ServiceSnapshot
    let weekCost: Double
    let isStale: Bool

    var body: some View {
        Text(weekCost < 100 ? String(format: "$%.1f", weekCost) : "$\(Int(weekCost.rounded()))")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isStale ? Color.secondary : Color.primary)
            .accessibilityLabel("\(service.displayName) spend \(Int(weekCost.rounded())) dollars this week")
    }
}

private struct MiniServiceBar: View {
    let service: ServiceSnapshot
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Double { service.headlinePercent }
    private var barColor: Color { usageStatusColor(percent) }
    private var isCritical: Bool { percent >= 95 }
    private var shouldPulse: Bool { isCritical && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: shouldPulse ? 0.05 : 0.5)) { ctx in
            // A gentle opacity pulse is the critical-state alert; no glow, and it
            // stays still when Reduce Motion is on.
            let pulse: Double = {
                guard shouldPulse else { return 1.0 }
                let t = ctx.date.timeIntervalSince1970
                return 0.55 + 0.45 * abs(sin(t * 2.5))
            }()

            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 22, height: 8)
                    Capsule(style: .continuous)
                        .fill(barColor)
                        .frame(width: max(2, 22 * percent / 100), height: 8)
                }
                .opacity(pulse)

                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? Color.secondary : barColor)
                    .opacity(pulse)
            }
            .animation(.easeInOut(duration: 0.4), value: percent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(service.displayName) usage \(Int(percent.rounded())) percent")
        }
    }
}
