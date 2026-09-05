import SwiftUI

struct DashboardWindow: View {
    @ObservedObject var appState: AppState
    @StateObject private var dashboard = DashboardState.shared
    /// Survives a relaunch. `Tab` is `String`-backed, so a raw value that no longer
    /// exists (a tab removed in a later release) falls back to `.overview` on its own.
    @AppStorage("dashboardTab") private var selection: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case agents = "Agents"
        case activity = "Activity"
        case history = "History"
        case insights = "Insights"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: return "chart.bar.doc.horizontal"
            case .agents: return "bolt.horizontal.circle"
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
            // Usage history is per provider, and so is cost now — but only for the
            // providers whose CLI writes a local log. Say which of the two this tab is
            // showing instead of letting the reader assume either way.
            .safeAreaInset(edge: .bottom) { sourceFooter }
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, idealWidth: 920, minHeight: 560, idealHeight: 640)
        .onAppear { dashboard.refreshAll() }
        // The poll path no longer pushes the full history into DashboardState —
        // while the window is open, each snapshot triggers the reload here; the
        // subscription dies with the window, so a closed dashboard costs nothing.
        .onReceive(NotificationCenter.default.publisher(for: .snapshotUpdated)) { _ in
            dashboard.refreshAll()
        }
    }

    private var sourceFooter: some View {
        let name = dashboard.displayName(for: dashboard.selectedService)
        let source = dashboard.costSource
        return Label(
            source.hasBreakdown ? "\(name) usage + CLI costs" : "\(name) usage history only",
            systemImage: source.hasBreakdown ? "sparkles" : "chart.line.uptrend.xyaxis"
        )
        .font(OMFont.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(source.longName.map { "Charts are built from \(name) usage history and \($0)." }
              ?? "Usage windows come from this provider. " + (source.reason ?? ""))
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview:
            OverviewView(appState: appState, dashboard: dashboard)
        case .agents:
            AgentsHistoryView(dashboard: dashboard)
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
    /// The Agents tab is not about one provider, so it hides the picker rather than
    /// showing a control that changes nothing on screen.
    var showsServicePicker: Bool = true

    @ObservedObject private var dashboard = DashboardState.shared

    var body: some View {
        // The header has to fit whatever width the window has, never the other way
        // round: a provider row plus a chart-mode switch plus a range picker is wider
        // than the default window, and a fixed-width HStack used to push the window
        // past the screen edge and squeeze the title to nothing. Widest layout that
        // fits wins; the title and subtitle always keep their line.
        ViewThatFits(in: .horizontal) {
            oneRow
            twoRows
            threeRows
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(OMFont.screenTitle)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var picker: some View {
        if showsServicePicker {
            ServicePicker(dashboard: dashboard)
        }
    }

    /// Title · provider row · controls, all on one line.
    private var oneRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            titleBlock
            Spacer(minLength: 12)
            picker
            trailing
        }
    }

    /// Title with the controls on its right, the provider row underneath.
    private var twoRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                trailing
            }
            picker
        }
    }

    /// Title, then the provider row, then the controls — for a window near its minimum.
    private var threeRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBlock
            picker
            trailing
        }
    }
}

/// Which provider the dashboard is about. Hidden until a second provider has
/// actually recorded something — a one-provider setup shouldn't pay screen space
/// for a control with a single option. One click per provider rather than a
/// drop-down: with three or four providers the menu was two clicks to answer
/// "and what does Codex look like?".
struct ServicePicker: View {
    @ObservedObject var dashboard: DashboardState

    var body: some View {
        if dashboard.availableServices.count > 1 {
            OMSegmentedControl(
                items: dashboard.availableServices.map { id in
                    OMSegmentItem(
                        id: id,
                        title: dashboard.displayName(for: id),
                        serviceID: id,
                        sfFallback: Self.iconName(for: id)
                    )
                },
                selection: Binding(
                    get: { dashboard.selectedService },
                    set: { dashboard.selectedService = $0 }
                ),
                alwaysShowsTitles: true,
                keyboardShortcuts: false
            )
            // The header is a flexible HStack; without this the row would stretch
            // across whatever the title leaves free.
            .fixedSize()
        }
    }

    /// The provider's own symbol while it is reporting. A provider that is on the
    /// list only because it has recorded history has no live snapshot to ask, and
    /// `ProviderIconView` falls back to this only when no bundled logo matches.
    @MainActor
    private static func iconName(for serviceID: String) -> String {
        AppState.shared.snapshot.services.first(where: { $0.id == serviceID })?.icon ?? "sparkles"
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
