import SwiftUI

/// The cost tile in the island's grid (`Main.dc.html`; notch-island spec 2026-10-29 § 3.3):
/// today's local $ accounting across providers — Claude's included — stacked to fit half
/// the grid: what it counts, the headline, the week and the per-provider split, and the
/// API-equivalent caption when any of those dollars are a subscription's. Over keep awake
/// with an even provider count; in the orphan slot, stretched to its row, with an odd one.
/// Callers hide it when `total == 0` (`ProviderGridRules.showsCostTile`).
///
/// Today leads because a week-only tile reads as a switch someone else made: a day
/// with no spend under a "Last 7 days $409.67" headline looks like the app quietly
/// changed the question. A machine whose cost logs have not been read yet has no
/// today to show and keeps the older, week-first shape.
struct OMCostTile: View {
    let services: [ServiceSnapshot]
    /// Today's dollars per service id, as `AppState` last gathered them. A service
    /// that is absent has no local cost log — which is not the same as having spent
    /// nothing, so the tile says nothing about today at all.
    var today: [String: Double] = [:]
    /// The week's dollars per service id, as `AppState` last gathered them; a service
    /// absent here keeps its snapshot's `weekCost`.
    var week: [String: Double] = [:]
    /// In a tile row's orphan slot the tile is as tall as the provider tile beside it.
    var fillsHeight: Bool = false

    // MARK: - Metrics (`Main.dc.html`)

    nonisolated static let surface: OMPopoverSurface = .group
    nonisolated static let titleSize: CGFloat = 12.5
    nonisolated static let secondarySize: CGFloat = 11.5
    nonisolated static let headlineSize: CGFloat = 22
    nonisolated static let captionSize: CGFloat = 11
    nonisolated static let verticalPadding: CGFloat = 12
    nonisolated static let horizontalPadding: CGFloat = 14

    // `View` is @MainActor, so these pure helpers say `nonisolated` to stay
    // callable from tests and from any other context.
    nonisolated static func total(_ services: [ServiceSnapshot], week: [String: Double] = [:]) -> Double {
        services.compactMap { weekCost(of: $0, week: week) }.reduce(0, +)
    }

    /// A service's week: the cost gathering's figure when it has one (a subscription's
    /// Claude snapshot carries none), else the snapshot's own `weekCost`.
    nonisolated static func weekCost(of service: ServiceSnapshot, week: [String: Double]) -> Double? {
        week[service.id] ?? service.weekCost
    }

    /// `locale` is the viewer's by default (the popover formats money the same
    /// way); tests pin it so the wording assertion doesn't depend on the machine.
    nonisolated static func breakdown(
        _ services: [ServiceSnapshot],
        week: [String: Double] = [:],
        locale: Locale = .current
    ) -> String {
        services.compactMap { s -> String? in
            guard let cost = weekCost(of: s, week: week), cost > 0 else { return nil }
            return "\(s.displayName) \(money(cost, locale: locale))"
        }
        .joined(separator: " · ")
    }

    nonisolated static func money(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
    }

    /// Today's dollars across the services on screen; nil when not one of them has a
    /// local cost log to read. Zero is an answer — "$0.00 today" is exactly what the
    /// tile exists to say — so only an absent entry makes today unknown.
    nonisolated static func todayTotal(_ services: [ServiceSnapshot], today: [String: Double]) -> Double? {
        let known = services.compactMap { today[$0.id] }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// VoiceOver reads the tile as one element, so the label has to carry the
    /// headline, what it is measuring and, on a subscription, what the dollars are.
    nonisolated static func accessibilityText(
        services: [ServiceSnapshot],
        today: [String: Double],
        week: [String: Double] = [:],
        locale: Locale = .current
    ) -> String {
        let todayTotal = todayTotal(services, today: today)
        let headline = todayTotal ?? total(services, week: week)
        let label = "\(title(todayKnown: todayTotal != nil)) \(money(headline, locale: locale))"
        guard let note = caption(services: services, today: today, week: week) else { return label }
        return "\(label). \(note)"
    }

    /// What the hero numeral is counting.
    nonisolated static func title(todayKnown: Bool) -> String {
        todayKnown ? "Today" : "Last 7 days"
    }

    /// `CostCopy`'s API-equivalent sentence when any provider with dollars in the tile
    /// (spent this week, or today) is on a subscription: there the figure is what the
    /// same tokens would cost through the API, not the bill. nil when every such
    /// provider is pay-as-you-go, or when no provider has dollars at all.
    nonisolated static func caption(
        services: [ServiceSnapshot],
        today: [String: Double] = [:],
        week: [String: Double] = [:]
    ) -> String? {
        let contributing = services.filter { (weekCost(of: $0, week: week) ?? 0) > 0 || (today[$0.id] ?? 0) > 0 }
        guard !contributing.isEmpty else { return nil }
        return CostCopy.apiEquivalentCaption(isPayAsYouGo: contributing.allSatisfy(CostCopy.isPayAsYouGo))
    }

    /// "Last 7 days $409.67 · Claude $408.03 · Codex $1.64" — the week keeps its
    /// number, in front of the per-provider split. With no today to lead with, the
    /// week is already the headline and repeating it here would say nothing.
    nonisolated static func secondary(
        services: [ServiceSnapshot],
        today: [String: Double],
        week: [String: Double] = [:],
        locale: Locale = .current
    ) -> String {
        let split = breakdown(services, week: week, locale: locale)
        guard todayTotal(services, today: today) != nil else { return split }
        let weekLine = "Last 7 days \(money(total(services, week: week), locale: locale))"
        return split.isEmpty ? weekLine : "\(weekLine) · \(split)"
    }

    var body: some View {
        let todayTotal = Self.todayTotal(services, today: today)
        let headline = todayTotal ?? Self.total(services, week: week)
        return VStack(alignment: .leading, spacing: 4) {
            Text(Self.title(todayKnown: todayTotal != nil))
                .font(.system(size: Self.titleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
            Text(Self.money(headline))
                .font(OMFont.numerals(size: Self.headlineSize, weight: .bold))
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(Self.secondary(services: services, today: today, week: week))
                .font(.system(size: Self.secondarySize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            // It qualifies every dollar in the tile.
            if let caption = Self.caption(services: services, today: today, week: week) {
                Text(caption)
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .popoverSurface(Self.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(services: services, today: today, week: week))
    }
}

#Preview {
    let a = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let b = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 8.2, state: .ok, stateMessage: nil, fetchedAt: Date())
    return OMCostTile(services: [a, b]).padding().frame(width: 220)
}
