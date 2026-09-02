import SwiftUI

struct MenuBarLabel: View {
    let snapshot: UsageSnapshot
    @ObservedObject private var settings = SettingsStore.shared

    private var displayServices: [ServiceSnapshot] {
        // A service earns a pill with rate windows OR (pay-as-you-go) a $ figure —
        // unless the user has taken it out of the menu bar.
        snapshot.services.filter {
            (!$0.buckets.isEmpty || $0.weekCost != nil) && settings.isShownInMenuBar($0.id)
        }
    }

    /// Several pills with numbers turn the menu bar into a ruler — the colored bars
    /// carry the signal on their own — so a lone provider keeps its number by default.
    /// Overridable both ways.
    private var showsNumber: Bool {
        switch settings.menuBarNumberMode {
        case .always: return true
        case .never: return false
        case .auto: return displayServices.count == 1
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            leadingSlot
            if displayServices.isEmpty {
                Image(systemName: "chart.bar")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayServices) { service in
                    if service.buckets.isEmpty, let cost = service.weekCost {
                        MiniCostPill(service: service, weekCost: cost, isStale: snapshot.isStale)
                    } else {
                        MiniServiceBar(service: service, isStale: snapshot.isStale, showsNumber: showsNumber)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 18)
        .opacity(snapshot.isStale ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.45), value: snapshot.headlinePercent)
    }

    /// Reserved for the phase-2 agents pill (count of live agent sessions).
    @ViewBuilder
    private var leadingSlot: some View {
        EmptyView()
    }
}

/// Pay-as-you-go pill: no rate windows to show, so the 7-day local spend is the number.
private struct MiniCostPill: View {
    let service: ServiceSnapshot
    let weekCost: Double
    let isStale: Bool

    var body: some View {
        Text(weekCost < 100 ? String(format: "$%.1f", weekCost) : "$\(Int(weekCost.rounded()))")
            .font(OMFont.menuNumeral)
            .monospacedDigit()
            .foregroundStyle(isStale ? Color.secondary : Color.primary)
            .accessibilityLabel("\(service.displayName) spend \(Int(weekCost.rounded())) dollars this week")
    }
}

private struct MiniServiceBar: View {
    let service: ServiceSnapshot
    let isStale: Bool
    let showsNumber: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Double { service.headlinePercent }
    private var barColor: Color { usageStatusColor(percent) }
    private var isCritical: Bool { percent >= 95 }
    private var shouldPulse: Bool { isCritical && !reduceMotion }

    var body: some View {
        // TimelineView(.animation) is a continuous redraw loop, so it only exists
        // while the critical-state pulse is actually needed — the status item's
        // hosting view never leaves the window, and a permanent timeline there
        // redraws the menu bar forever.
        if shouldPulse {
            TimelineView(.animation(minimumInterval: 0.05)) { ctx in
                // A gentle opacity pulse is the critical-state alert; no glow, and it
                // stays still when Reduce Motion is on.
                let t = ctx.date.timeIntervalSince1970
                content(pulse: 0.55 + 0.45 * abs(sin(t * 2.5)))
            }
        } else {
            content(pulse: 1.0)
        }
    }

    private func content(pulse: Double) -> some View {
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

            if showsNumber {
                Text("\(Int(percent.rounded()))")
                    .font(OMFont.menuNumeral)
                    .monospacedDigit()
                    .foregroundStyle(isStale ? Color.secondary : barColor)
                    .opacity(pulse)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(service.displayName) usage \(Int(percent.rounded())) percent")
    }
}
