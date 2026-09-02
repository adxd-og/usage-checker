import SwiftUI

/// Control-Center style tile for the All tab: icon · name · plan, the hero
/// window as a ring with its label and time left, the secondary window as a
/// thin bar. A provider that can't report right now shows its state chip
/// instead of the ring and dims. The whole tile is a button (→ provider tab).
struct OMProviderTile: View {
    let service: ServiceSnapshot
    let action: () -> Void

    private var hero: UsageBucket? { WindowRanking.heroBucket(for: service) }
    private var secondary: UsageBucket? { WindowRanking.secondaryBucket(for: service) }
    private var isHealthy: Bool { service.state == .ok }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: OMSpacing.s) {
                header
                middle
                footer
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).fill(OMSurface.tile))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).strokeBorder(OMSurface.hairline, lineWidth: 0.5))
            .opacity(isHealthy ? 1 : 0.7)
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderIconView(serviceID: service.id, sfFallback: service.icon, size: 16)
                .foregroundStyle(.tint)
            Text(service.displayName).font(OMFont.bodyStrong).lineLimit(1)
            Spacer(minLength: 4)
            if let plan = service.plan {
                Text(plan).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var middle: some View {
        HStack(spacing: 9) {
            if isHealthy, let hero {
                OMRing(percent: hero.clampedPercent, size: .medium, pace: hero.elapsedFraction())
                VStack(alignment: .leading, spacing: 2) {
                    Text(WindowRanking.shortWindowLabel(hero.label))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(WindowRanking.remainingText(until: hero.resetsAt) ?? "")
                        .font(OMFont.caption.weight(.semibold))
                }
            } else if isHealthy, let cost = service.weekCost {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last 7 days").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(OMFont.numeral).monospacedDigit()
                }
            } else {
                OMChip(text: stateText, tint: stateTint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if isHealthy, let secondary {
            VStack(alignment: .leading, spacing: 3) {
                BarSegment(percent: secondary.clampedPercent, height: 5, showsLabel: false)
                Text("\(WindowRanking.shortWindowLabel(secondary.label)) \(Int(secondary.clampedPercent.rounded()))%")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var stateText: String {
        switch service.state {
        case .notSignedIn: "Sign in"
        case .notRunning: "Not running"
        case .error: "Error"
        case .ok: "OK"
        }
    }
    private var stateTint: Color {
        switch service.state {
        case .notSignedIn: .orange
        case .notRunning: .secondary
        case .error: .red
        case .ok: .green
        }
    }
    private var accessibilityText: String {
        if let hero, isHealthy {
            return "\(service.displayName), \(hero.label) \(Int(hero.clampedPercent.rounded())) percent used"
        }
        return "\(service.displayName), \(stateText)"
    }
}

#Preview("Tiles") {
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 37, resetsAt: Date().addingTimeInterval(8100), kind: .session)
    let weekly = UsageBucket(id: "seven_day", label: "All models", utilization: 52, resetsAt: Date().addingTimeInterval(86400 * 2), kind: .weekly)
    let ok = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: "Max 20x", accountLabel: nil, buckets: [session, weekly], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let signedOut = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: nil, state: .notSignedIn, stateMessage: "Sign in", fetchedAt: Date())
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        OMProviderTile(service: ok) {}
        OMProviderTile(service: signedOut) {}
    }
    .padding().frame(width: 328)
}
