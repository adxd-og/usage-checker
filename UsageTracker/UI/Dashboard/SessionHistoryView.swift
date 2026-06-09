import SwiftUI
import Charts

struct SessionHistoryView: View {
    @ObservedObject var dashboard: DashboardState

    private var data: [DailyPoint] {
        let daily = dashboard.cliBreakdown?.daily ?? []
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-dashboard.range.seconds))
        return daily
            .filter { $0.day >= cutoff }
            .map { DailyPoint(day: $0.day, cost: $0.totalCost, tokens: $0.totalTokens, turns: $0.turns) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: "Session history",
                    subtitle: "Daily cost over the selected range",
                    trailing: AnyView(RangePicker(range: $dashboard.range))
                )

                if data.isEmpty {
                    placeholder
                } else {
                    chart
                    Divider().padding(.horizontal, 24)
                    table
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var chart: some View {
        Chart(data) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Cost ($)", point.cost)
            )
            .foregroundStyle(barGradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, data.count / 8))) { mark in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(minHeight: 260)
        .padding(.horizontal, 24)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Day").font(.subheadline).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                Spacer()
                Text("Turns").font(.subheadline).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                Text("Tokens").font(.subheadline).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                Text("Cost").font(.subheadline).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(data.reversed()) { p in
                HStack {
                    Text(p.day.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                    Text("\(p.turns)").font(.subheadline).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text(formatTokens(p.tokens)).font(.subheadline).monospacedDigit().frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", p.cost)).font(.subheadline).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if p.id != data.first?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No CLI usage recorded yet")
                .foregroundStyle(.secondary)
            Text("Run a `claude` session to start collecting data")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct DailyPoint: Identifiable {
    let day: Date
    let cost: Double
    let tokens: Int
    let turns: Int
    var id: Date { day }
}
