import SwiftUI

/// The two lines beside a tile's ring, or over its bar.
struct OMTileCaption: Equatable, Sendable {
    let title: String
    let value: String?
}

/// Control-Center style tile for the All tab: icon · name · plan, the hero window
/// as a ring with its label and time left, the secondary window as a thin bar.
///
/// A provider that can't report right now keeps whatever it last reported — the
/// bars stay, dimmed, and the state chip moves under them with an "as of" stamp.
/// Only a provider with no numbers at all is reduced to its chip.
struct OMProviderTile: View {
    let service: ServiceSnapshot
    let mode: PercentDisplay.Mode
    let action: () -> Void

    private var hero: UsageBucket? { WindowRanking.tileHero(for: service) }
    private var secondary: UsageBucket? { WindowRanking.secondaryBucket(for: service) }
    /// "Has something to draw", not "is healthy" — that distinction is the whole fix.
    private var hasData: Bool { !service.buckets.isEmpty }
    private var numbersOpacity: Double { service.isRetained ? 0.55 : 1 }

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
            // A retained tile is not dimmed as a whole: its numbers are, and its
            // chip has to stay legible.
            .opacity(service.state == .ok || service.isRetained ? 1 : 0.7)
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(for: service, hero: hero, mode: mode))
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
            if let hero {
                let caption = Self.heroCaption(for: service, hero: hero)
                HStack(spacing: 9) {
                    OMRing(used: hero.clampedPercent, mode: mode, size: .medium, pace: hero.elapsedFraction())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(caption.title)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        // A spend limit or a weekly budget has no reset: no empty line.
                        if let value = caption.value {
                            Text(value)
                                .font(OMFont.caption.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
                .opacity(numbersOpacity)
            } else if let cost = service.spendHeadline {
                // Pay-as-you-go without windows: live, or last known and dimmed like any
                // retained number, with the chip in the footer saying why.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last 7 days").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(OMFont.numeral).monospacedDigit()
                }
                .opacity(numbersOpacity)
            } else if !hasData {
                stateRow
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    /// The chip lives here whenever there are numbers above it, so it reads as a
    /// footnote on the tile rather than as the tile's content.
    @ViewBuilder
    private var footer: some View {
        if service.isRetained {
            VStack(alignment: .leading, spacing: 3) {
                if let secondary {
                    BarSegment(used: secondary.clampedPercent, mode: mode, height: 5, showsLabel: false)
                        .opacity(numbersOpacity)
                }
                stateRow
            }
        } else if service.state == .ok, let secondary {
            VStack(alignment: .leading, spacing: 3) {
                BarSegment(used: secondary.clampedPercent, mode: mode, height: 5, showsLabel: false)
                Text("\(WindowRanking.shortWindowLabel(secondary.label)) \(PercentDisplay.percentText(secondary.clampedPercent, mode: mode))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var stateRow: some View {
        HStack(spacing: 5) {
            OMChip(text: RetainedCopy.chipText(for: service.state), tint: stateTint)
            if let suffix = RetainedCopy.chipSuffix(for: service) {
                Text(suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var stateTint: Color { Self.chipTint(for: service.state) }

    /// The state chip's colour. Shared with the floating panel, which puts the same chip
    /// over the same retained numbers.
    static func chipTint(for state: ServiceState) -> Color {
        switch state {
        case .notSignedIn: .orange
        case .notRunning: .secondary
        case .error: .red
        case .ok: .secondary
        }
    }

    /// Pure so the wording is unit-tested: VoiceOver can't see that the ring is
    /// dimmed, so the label has to say the numbers are last known.
    nonisolated static func accessibilityText(
        for service: ServiceSnapshot, hero: UsageBucket?, mode: PercentDisplay.Mode = .used
    ) -> String {
        let state = RetainedCopy.chipText(for: service.state)
        guard let hero else { return "\(service.displayName), \(state)" }
        let reading = "\(hero.label) \(PercentDisplay.spoken(hero.clampedPercent, mode: mode))"
        guard service.isRetained else { return "\(service.displayName), \(reading)" }
        return "\(service.displayName), \(reading), last known, \(state)"
    }

    /// The two lines beside the ring. A live window counts down ("11m left"); a
    /// spend limit, which never resets, shows the dollars its ring measures. A
    /// retained service's numbers are old, and once its reset has passed the
    /// countdown read "resets now" — a closed Antigravity's tile said so for hours —
    /// so it dates them instead: "Last known 12:50".
    nonisolated static func heroCaption(
        for service: ServiceSnapshot,
        hero: UsageBucket,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> OMTileCaption {
        if let stamp = RetainedCopy.lastKnownStamp(for: service, now: now, calendar: calendar, locale: locale) {
            return OMTileCaption(title: RetainedCopy.lastKnownTitle, value: stamp)
        }
        let title = WindowRanking.shortWindowLabel(hero.label)
        if let remaining = WindowRanking.remainingText(until: hero.resetsAt, now: now) {
            return OMTileCaption(title: title, value: remaining)
        }
        if hero.id == WindowRanking.extraUsageBucketID(for: service) {
            return OMTileCaption(title: title, value: SpendLimitCopy.caption(service.extraUsage, compact: true))
        }
        return OMTileCaption(title: title, value: nil)
    }
}

#Preview("Tiles") {
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 37, resetsAt: Date().addingTimeInterval(8100), kind: .session)
    let weekly = UsageBucket(id: "seven_day", label: "All models", utilization: 52, resetsAt: Date().addingTimeInterval(86400 * 2), kind: .weekly)
    let ok = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: "Max 20x", accountLabel: nil, buckets: [session, weekly], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let retained = ServiceSnapshot(id: "antigravity", displayName: "Antigravity", icon: "circle.grid.cross", plan: "Antigravity Pro", accountLabel: nil, buckets: [session, weekly], extraUsage: nil, weekCost: nil, state: .notRunning, stateMessage: "Antigravity isn't running", fetchedAt: Date().addingTimeInterval(-3600))
    let signedOut = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: nil, state: .notSignedIn, stateMessage: "Sign in", fetchedAt: Date())
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        OMProviderTile(service: ok, mode: .used) {}
        OMProviderTile(service: retained, mode: .used) {}
        OMProviderTile(service: signedOut, mode: .used) {}
    }
    .padding().frame(width: 328)
}
