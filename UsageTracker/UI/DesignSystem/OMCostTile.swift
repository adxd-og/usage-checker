import SwiftUI

/// Full-width cost tile on the All tab (`Main.dc.html`): today's local $ accounting
/// across providers — Claude's included — with the week's total and the per-provider
/// breakdown on the line below, and the API-equivalent caption under both when any of
/// those dollars are a subscription's. Callers hide it when `total == 0`.
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
    nonisolated static func total(_ services: [ServiceSnapshot]) -> Double {
        services.compactMap(\.weekCost).reduce(0, +)
    }

    /// `locale` is the viewer's by default (the popover formats money the same
    /// way); tests pin it so the wording assertion doesn't depend on the machine.
    nonisolated static func breakdown(_ services: [ServiceSnapshot], locale: Locale = .current) -> String {
        services.compactMap { s -> String? in
            guard let cost = s.weekCost, cost > 0 else { return nil }
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
        locale: Locale = .current
    ) -> String {
        let todayTotal = todayTotal(services, today: today)
        let headline = todayTotal ?? total(services)
        let label = "\(title(todayKnown: todayTotal != nil)) \(money(headline, locale: locale))"
        guard let note = caption(services: services, today: today) else { return label }
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
    nonisolated static func caption(services: [ServiceSnapshot], today: [String: Double] = [:]) -> String? {
        let contributing = services.filter { ($0.weekCost ?? 0) > 0 || (today[$0.id] ?? 0) > 0 }
        guard !contributing.isEmpty else { return nil }
        return CostCopy.apiEquivalentCaption(isPayAsYouGo: contributing.allSatisfy(CostCopy.isPayAsYouGo))
    }

    /// "Last 7 days $409.67 · Claude $408.03 · Codex $1.64" — the week keeps its
    /// number, in front of the per-provider split. With no today to lead with, the
    /// week is already the headline and repeating it here would say nothing.
    nonisolated static func secondary(
        services: [ServiceSnapshot],
        today: [String: Double],
        locale: Locale = .current
    ) -> String {
        let split = breakdown(services, locale: locale)
        guard todayTotal(services, today: today) != nil else { return split }
        let week = "Last 7 days \(money(total(services), locale: locale))"
        return split.isEmpty ? week : "\(week) · \(split)"
    }

    var body: some View {
        let todayTotal = Self.todayTotal(services, today: today)
        let headline = todayTotal ?? Self.total(services)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(todayKnown: todayTotal != nil))
                        .font(.system(size: Self.titleSize, weight: .semibold))
                        .foregroundStyle(.om(.text))
                    Text(Self.secondary(services: services, today: today))
                        .font(.system(size: Self.secondarySize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(Self.money(headline))
                    .font(OMFont.numerals(size: Self.headlineSize, weight: .bold))
                    .foregroundStyle(.om(.text))
            }
            // Full width under the numbers: the sentence is too long for the column
            // beside the hero numeral, and it qualifies every dollar in the tile.
            if let caption = Self.caption(services: services, today: today) {
                Text(caption)
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverSurface(Self.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(services: services, today: today))
    }
}

#Preview {
    let a = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let b = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 8.2, state: .ok, stateMessage: nil, fetchedAt: Date())
    return OMCostTile(services: [a, b]).padding().frame(width: 360)
}
