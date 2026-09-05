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

    /// The line the status item's tooltip and VoiceOver read for one pill. Pure so
    /// the retained wording is tested: 22 points of bar and two digits can't say
    /// "these numbers are an hour old", and the dimming alone is easy to miss.
    nonisolated static func text(
        for service: ServiceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let percent = Int(service.headlinePercent.rounded())
        guard let at = service.retainedAt else {
            return "\(service.displayName) usage \(percent)%"
        }
        let stamp = RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale)
        return "\(service.displayName): last known \(percent)% (as of \(stamp)) — \(RetainedCopy.chipText(for: service.state))"
    }

    /// The agents pill. A separate view, not an `@ObservedObject` on `MenuBarLabel`
    /// itself: see `AgentsPillSlot`.
    @ViewBuilder
    private var leadingSlot: some View {
        AgentsPillSlot()
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
    /// A frozen 96% is not an emergency: the provider stopped reporting, so the
    /// number isn't climbing and the pulse would be crying wolf.
    private var shouldPulse: Bool { isCritical && !reduceMotion && !service.isRetained }
    /// Last-known numbers read at the same strength as live ones without this.
    private var retainedDim: Double { service.isRetained ? 0.55 : 1 }

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
            .opacity(pulse * retainedDim)

            if showsNumber {
                Text("\(Int(percent.rounded()))")
                    .font(OMFont.menuNumeral)
                    .monospacedDigit()
                    .foregroundStyle(isStale ? Color.secondary : barColor)
                    .opacity(pulse * retainedDim)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MenuBarLabel.text(for: service))
    }
}

/// Bridges `AgentSessionStore` into the menu bar.
///
/// The observation lives here rather than on `MenuBarLabel` on purpose. The store
/// republishes on every hook event — a tool starting is an event — and observing it
/// one level up would re-evaluate every provider pill each time an agent ran `Read`.
/// Confined to this view, an event that moves none of the three counts re-evaluates
/// these four lines and stops: SwiftUI compares `OMAgentsPill`'s stored `Int`s,
/// finds them unchanged and skips its body, so nothing is redrawn. Nothing on this
/// path is driven by a timer.
private struct AgentsPillSlot: View {
    @ObservedObject private var store = AgentSessionStore.shared

    var body: some View {
        OMAgentsPill(
            needsYou: store.needsYouCount,
            working: store.workingCount,
            total: store.sessions.count
        )
    }
}
