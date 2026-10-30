import SwiftUI

/// The two lines beside a tile's ring, or over its bar.
struct OMTileCaption: Equatable, Sendable {
    let title: String
    let value: String?
}

/// A line of text and the colour token it is drawn in.
struct OMColoredText: Equatable, Sendable {
    let text: String
    let token: OMColorToken
}

/// A provider's tile in the island's grid (`Main.dc.html`; notch-island spec 2026-10-29
/// § 3.3): logo, name and — on its own line — the plan, with the needs-you dot on the right
/// while one of its sessions waits; the hero window as a slim ring with its label and time
/// left; the all-models weekly as a thin bar between its label, in the column every tile in
/// the grid shares, and its figure. Captions shrink first and truncate at their tail last;
/// they never overflow.
///
/// A provider that can't report right now keeps whatever it last reported: the ring
/// stays, muted and dimmed, the line under the name says why ("Not running"), and the
/// ring's caption dates the numbers ("Last known 12:50"). A provider with nothing to
/// show is its name and its state in colour. No chips (spec § Principles 2).
struct OMProviderTile: View {
    let service: ServiceSnapshot
    let mode: PercentDisplay.Mode
    /// The bar-label column every tile in the grid shares (`ProviderGridRules.barLabelWidth`).
    let barLabelWidth: CGFloat
    /// One of this provider's sessions waits for the user (`ProviderGridRules.showsWaitingDot`).
    var showsWaitingDot: Bool = false
    let action: () -> Void

    private var hero: UsageBucket? { WindowRanking.tileHero(for: service) }
    private var secondary: UsageBucket? { WindowRanking.secondaryBucket(for: service) }
    private var contentOpacity: Double { service.isRetained ? Self.retainedOpacity : 1 }

    // MARK: - Metrics (`Main.dc.html`)

    nonisolated static let surface: OMPopoverSurface = .tile
    nonisolated static let padding: CGFloat = 12
    nonisolated static let sectionSpacing: CGFloat = 11
    nonisolated static let rowSpacing: CGFloat = 9
    nonisolated static let logoSize: CGFloat = 22
    nonisolated static let logoGlyph: CGFloat = 18
    nonisolated static let nameSize: CGFloat = 13
    nonisolated static let subtitleSize: CGFloat = 11
    nonisolated static let captionTitleSize: CGFloat = 11
    nonisolated static let captionValueSize: CGFloat = 13
    nonisolated static let captionUnitSize: CGFloat = 11.5
    nonisolated static let barLabelSize: CGFloat = 11.5
    nonisolated static let barHeight: CGFloat = 4
    /// A retained tile's name line and numbers (`Main.dc.html`'s Antigravity).
    nonisolated static let retainedOpacity: Double = 0.55
    /// The bar row (notch-island spec § 3.3): label, bar and figure, this far apart; the
    /// figure takes `barValueWidth`.
    nonisolated static let barGap: CGFloat = 8
    nonisolated static let barValueWidth: CGFloat = 36
    /// The needs-you dot in the tile's header (the prototype's 7 px dot).
    nonisolated static let waitingDotDiameter: CGFloat = 7

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header
                middle
                footer
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .popoverSurface(Self.surface)
            .contentShape(OMCornerShape(Self.surface.corner))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(for: service, hero: hero, mode: mode))
    }

    private var header: some View {
        HStack(spacing: Self.rowSpacing) {
            HStack(spacing: Self.rowSpacing) {
                ProviderIconView(serviceID: service.id, sfFallback: service.icon, size: Self.logoGlyph)
                    .foregroundStyle(.om(.text))
                    .frame(width: Self.logoSize, height: Self.logoSize)
                VStack(alignment: .leading, spacing: 0) {
                    Text(service.displayName)
                        .font(.system(size: Self.nameSize, weight: .semibold))
                        .foregroundStyle(.om(.text))
                    if let subtitle = Self.subtitle(for: service) {
                        Text(subtitle.text)
                            .font(.system(size: Self.subtitleSize))
                            .foregroundStyle(.om(subtitle.token))
                    }
                }
                .lineLimit(1)
            }
            // A retained provider dims its name; a waiting session is live news, so the dot
            // keeps full strength.
            .opacity(contentOpacity)
            Spacer(minLength: 0)
            if showsWaitingDot {
                Circle()
                    .fill(.om(OMSegmentedControl.needsYouDotToken))
                    .frame(width: Self.waitingDotDiameter, height: Self.waitingDotDiameter)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var middle: some View {
        if let hero {
            let caption = Self.heroCaption(for: service, hero: hero)
            HStack(spacing: Self.rowSpacing) {
                OMRing(
                    used: hero.clampedPercent, mode: mode, size: .medium,
                    pace: hero.elapsedFraction(), style: .slim, muted: service.isRetained
                )
                captionStack(caption)
                Spacer(minLength: 0)
            }
            .opacity(contentOpacity)
        } else if let cost = service.spendHeadline {
            // Pay-as-you-go without windows: live, or last known and dimmed like any
            // retained number, dated by its title.
            captionStack(OMTileCaption(title: Self.spendTitle(for: service), value: OMCostTile.money(cost)))
                .opacity(contentOpacity)
        }
    }

    private func captionStack(_ caption: OMTileCaption) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption.title)
                .font(.system(size: Self.captionTitleSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            if let value = caption.value {
                // Shrinks first, truncates last (§ 3.3: never overflow).
                OMFigureText(text: value, size: Self.captionValueSize, unitSize: Self.captionUnitSize, unitWeight: .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }
        }
    }

    /// The all-models weekly (or the next window) as "Week ▬▬▬ 41%" on one line: the label
    /// in the grid's shared column, so every tile's bar starts at the same x, then the bar,
    /// then the figure. For a live tile and, dimmed, for a retained one.
    @ViewBuilder
    private var footer: some View {
        if let secondary, service.state == .ok || service.isRetained {
            let line = Self.secondaryLine(secondary, mode: mode)
            HStack(spacing: Self.barGap) {
                Text(line.title)
                    .font(.system(size: Self.barLabelSize))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: barLabelWidth, alignment: .leading)
                BarSegment(used: secondary.clampedPercent, mode: mode, height: Self.barHeight, style: .slim)
                Text(line.value ?? "")
                    .font(OMFont.numerals(size: Self.barLabelSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                    .frame(width: Self.barValueWidth, alignment: .trailing)
            }
            .opacity(contentOpacity)
        }
    }

    // MARK: - Rules (pure, unit-tested)

    /// A window's name on a 160 pt tile: any session window is "Session", the
    /// all-models weekly "Week"; "Opus only" → "Opus" as before.
    nonisolated static func shortLabel(for bucket: UsageBucket) -> String {
        if bucket.kind == .session { return "Session" }
        if bucket.id == "seven_day" { return "Week" }
        return WindowRanking.shortWindowLabel(bucket.label)
    }

    /// The line under the name: the plan while the provider is live and has numbers;
    /// otherwise its state, in its colour ("Not running", "Sign in", "Error", "No data").
    /// "Has numbers" is `WindowRanking`'s own answer — a hero exists, which counts an
    /// enabled extra-usage or spend limit — or a windowless account's week of dollars,
    /// so a tile that draws a ring never says "No data".
    nonisolated static func subtitle(for service: ServiceSnapshot) -> OMColoredText? {
        let hasNumbers = WindowRanking.detailHero(for: service) != nil || service.spendHeadline != nil
        if service.state != .ok || !hasNumbers {
            return OMColoredText(text: RetainedCopy.chipText(for: service.state), token: stateToken(for: service.state))
        }
        return PopoverCopy.planLine(plan: service.plan, displayName: service.displayName)
            .map { OMColoredText(text: $0, token: .secondary) }
    }

    /// A state's colour as text: amber when signing in would fix it, red for an error,
    /// secondary for a closed app or an empty reply.
    nonisolated static func stateToken(for state: ServiceState) -> OMColorToken {
        switch state {
        case .notSignedIn: .warning
        case .error: .critical
        case .notRunning, .ok: .secondary
        }
    }

    /// "Week" and "41%" over the thin bar.
    nonisolated static func secondaryLine(_ bucket: UsageBucket, mode: PercentDisplay.Mode) -> OMTileCaption {
        OMTileCaption(title: shortLabel(for: bucket), value: PercentDisplay.percentText(bucket.clampedPercent, mode: mode))
    }

    /// The label left of the tile's bar ("Week", "Credits", "Opus"), which the grid's
    /// shared column is sized to; nil when the tile draws no bar: nothing under the hero,
    /// or a provider that is neither live nor retained.
    nonisolated static func barLabel(for service: ServiceSnapshot) -> String? {
        guard service.state == .ok || service.isRetained,
              let secondary = WindowRanking.secondaryBucket(for: service)
        else { return nil }
        return shortLabel(for: secondary)
    }

    /// A windowless account's headline title: "Last 7 days", dated when retained
    /// ("Last 7 days · as of 12:50").
    nonisolated static func spendTitle(
        for service: ServiceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let suffix = RetainedCopy.chipSuffix(for: service, now: now, calendar: calendar, locale: locale)
        else { return "Last 7 days" }
        return "Last 7 days \(suffix)"
    }

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

    /// The two lines beside the ring. A live window counts down ("Session / 11m
    /// left"); a spend limit, which never resets, shows the dollars its ring measures.
    /// A retained service's numbers are old, and once its reset has passed the
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
        let title = shortLabel(for: hero)
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
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 57, resetsAt: Date().addingTimeInterval(660), kind: .session)
    let weekly = UsageBucket(id: "seven_day", label: "All models", utilization: 41, resetsAt: Date().addingTimeInterval(86400 * 2), kind: .weekly)
    let ok = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: "Max 20x", accountLabel: nil, buckets: [session, weekly], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let retained = ServiceSnapshot(id: "antigravity", displayName: "Antigravity", icon: "circle.grid.cross", plan: "Antigravity Pro", accountLabel: nil, buckets: [session], extraUsage: nil, weekCost: nil, state: .notRunning, stateMessage: "Antigravity isn't running", fetchedAt: Date().addingTimeInterval(-3600))
    let signedOut = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: nil, state: .notSignedIn, stateMessage: "Sign in", fetchedAt: Date())
    return VStack(spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
            OMProviderTile(service: ok, mode: .used, barLabelWidth: 40, showsWaitingDot: true) {}
            OMProviderTile(service: retained, mode: .used, barLabelWidth: 40) {}
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 10) {
            OMProviderTile(service: signedOut, mode: .used, barLabelWidth: 40) {}
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(width: 450)
    .background(OMWindowBackground())
}
