import SwiftUI

struct DashboardWindow: View {
    @ObservedObject var appState: AppState
    @StateObject private var dashboard = DashboardState.shared
    @State private var selection: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case history = "History"
        case insights = "Insights"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: return "chart.bar.doc.horizontal"
            case .activity: return "square.grid.4x3.fill"
            case .history: return "clock"
            case .insights: return "lightbulb"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, idealWidth: 920, minHeight: 560, idealHeight: 640)
        .onAppear { dashboard.refreshAll() }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview:
            OverviewView(appState: appState, dashboard: dashboard)
        case .activity:
            ActivityGridView(dashboard: dashboard)
        case .history:
            SessionHistoryView(dashboard: dashboard)
        case .insights:
            InsightsView(dashboard: dashboard)
        }
    }
}

// MARK: - Common chrome

struct DashboardHeader: View {
    let title: String
    let subtitle: String?
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}

struct RangePicker: View {
    @Binding var range: TimeRange

    var body: some View {
        Picker("", selection: $range) {
            ForEach(TimeRange.allCases) { r in
                Text(r.displayName).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
    }
}
