import SwiftUI

/// Full-width "Last 7 days" tile on the All tab: total local $ accounting across
/// providers plus a per-provider breakdown. Callers hide it when `total == 0`.
struct OMCostTile: View {
    let services: [ServiceSnapshot]

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

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last 7 days").font(OMFont.bodyStrong)
                Text(Self.breakdown(services)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Self.money(Self.total(services)))
                .font(OMFont.heroNumeral)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).fill(OMSurface.tile))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).strokeBorder(OMSurface.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last 7 days \(Self.money(Self.total(services)))")
    }
}

#Preview {
    let a = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let b = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 8.2, state: .ok, stateMessage: nil, fetchedAt: Date())
    return OMCostTile(services: [a, b]).padding().frame(width: 328)
}
