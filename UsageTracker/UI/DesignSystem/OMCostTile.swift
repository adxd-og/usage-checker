import SwiftUI

/// Full-width cost tile on the All tab: today's local $ accounting across providers,
/// with the week's total and the per-provider breakdown on the line below. Callers
/// hide it when `total == 0`.
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

    /// VoiceOver reads the tile as one element, so the label has to carry both the
    /// headline and what it is measuring.
    nonisolated static func accessibilityText(
        services: [ServiceSnapshot],
        today: [String: Double],
        locale: Locale = .current
    ) -> String {
        let todayTotal = todayTotal(services, today: today)
        let headline = todayTotal ?? total(services)
        return "\(title(todayKnown: todayTotal != nil)) \(money(headline, locale: locale))"
    }

    /// What the hero numeral is counting.
    nonisolated static func title(todayKnown: Bool) -> String {
        todayKnown ? "Today" : "Last 7 days"
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
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(todayKnown: todayTotal != nil)).font(OMFont.bodyStrong)
                Text(Self.secondary(services: services, today: today))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Self.money(headline))
                .font(OMFont.heroNumeral)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).fill(OMSurface.tile))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).strokeBorder(OMSurface.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(services: services, today: today))
    }
}

#Preview {
    let a = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let b = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 8.2, state: .ok, stateMessage: nil, fetchedAt: Date())
    return OMCostTile(services: [a, b]).padding().frame(width: 328)
}
