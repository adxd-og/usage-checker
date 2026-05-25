import SwiftUI

struct MenuBarLabel: View {
    let snapshot: UsageSnapshot

    private var displayServices: [ServiceSnapshot] {
        snapshot.services.filter { !$0.buckets.isEmpty }
    }

    var body: some View {
        HStack(spacing: 4) {
            if displayServices.isEmpty {
                Image(systemName: "chart.bar")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayServices) { service in
                    MiniServiceBar(service: service, isStale: snapshot.isStale)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 18)
        .opacity(snapshot.isStale ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.45), value: snapshot.headlinePercent)
    }
}

private struct MiniServiceBar: View {
    let service: ServiceSnapshot
    let isStale: Bool

    private var percent: Double { service.headlinePercent }

    private var ringColor: Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .accentColor
    }

    private var isCritical: Bool { percent >= 95 }

    var body: some View {
        TimelineView(.animation(minimumInterval: isCritical ? 0.05 : 0.5)) { ctx in
            let pulse: Double = {
                guard isCritical else { return 1.0 }
                let t = ctx.date.timeIntervalSince1970
                return 0.55 + 0.45 * abs(sin(t * 2.5))
            }()

            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 22, height: 8)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: percent >= 70
                                    ? [ringColor, ringColor.opacity(0.7)]
                                    : [ringColor.opacity(0.9), .cyan.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, 22 * percent / 100), height: 8)
                        .shadow(color: isCritical ? .red.opacity(0.7 * pulse) : .clear, radius: isCritical ? 3 : 0)
                }
                .opacity(isCritical ? pulse : 1.0)

                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? Color.secondary : ringColor)
                    .opacity(isCritical ? pulse : 1.0)
            }
            .animation(.easeInOut(duration: 0.4), value: percent)
        }
    }
}
