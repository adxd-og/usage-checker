import SwiftUI

struct DashboardWindow: View {
    @ObservedObject var appState: AppState
    @StateObject private var dashboard = DashboardState.shared
    /// Survives a relaunch, under 2.x's key. Read through `DashboardTab.route(storedValue:)`:
    /// 2.x's Activity tab reopens on History, and a value no tab answers to on Overview.
    @AppStorage(DashboardTab.storageKey) private var storedTab: String = DashboardTab.overview.rawValue
    /// See `DetailRebuildRule`: a text created while this window is hidden comes
    /// back upside down on macOS 27.0, so the column is rebuilt when the window shows.
    @State private var rebuildRule = DetailRebuildRule()
    @State private var detailGeneration = 0

    typealias Tab = DashboardTab

    private var selection: Tab { Tab.route(storedValue: storedTab) }

    /// The sidebar's selection: routed on the way in, stored by raw value on the way out.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { Tab.route(storedValue: storedTab) },
            set: { storedTab = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(selection: tabSelection) {
                // How fresh the numbers are (spec § Removals: it replaces the data-source
                // line). Its text changes while the window is hidden, so it is rebuilt
                // with the detail column when the window comes back (`DetailRebuildRule`).
                UpdatedFootnote(snapshot: appState.snapshot)
                    .padding(.horizontal, UpdatedFootnoteRules.horizontalPadding)
                    .id(detailGeneration)
            }
            .padding([.top, .bottom, .leading], DashboardShellLayout.windowInset)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Figures and chat titles are worth copying out of the app. One
                // modifier on the detail root and every tab inherits it.
                .textSelection(.enabled)
                .id(detailGeneration)
                .padding([.top, .bottom, .trailing], DashboardShellLayout.windowInset)
        }
        // The sidebar reaches up under the traffic lights, `windowInset` below the
        // window's top edge. The scene hides the title bar (`.windowStyle(.hiddenTitleBar)`
        // in `UsageTrackerApp`) and the shell draws into its strip: the backdrop, its
        // tint and the sidebar's glass are the whole chrome (spec § Components, "Sidebar").
        .ignoresSafeArea(.container, edges: .top)
        .background {
            ZStack {
                OMWindowBackground()
                // The window's body over the backdrop (ruling R4, `windowTint`).
                Rectangle()
                    .fill(.om(.windowTint))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .frame(
            minWidth: DashboardShellLayout.minWidth,
            idealWidth: DashboardShellLayout.idealWidth,
            minHeight: DashboardShellLayout.minHeight,
            idealHeight: DashboardShellLayout.idealHeight
        )
        .onAppear {
            dashboard.refreshAll()
            Updater.shared.checkInBackgroundIfDue()
        }
        // A closed `Window` is hidden, not gone: this view and its subscriptions
        // outlive the close. The window's own visibility decides when the column
        // is rebuilt; it also skips the refresh below while hidden, though other
        // publishers (`appState`, `dashboard`) still reach the hidden views — the
        // rebuild on showing is what actually cures them.
        .background(WindowVisibilityReader { visible in
            if rebuildRule.windowVisibilityChanged(visible) {
                detailGeneration += 1
                dashboard.refreshAll()
            }
        })
        // The traffic lights inside the sidebar panel, as the mockups draw them; the
        // hidden title bar alone leaves them straddling its top edge.
        .background(WindowButtonsPlacement())
        // The poll path no longer pushes the full history into DashboardState —
        // while the window is on screen, each snapshot triggers the reload here.
        .onReceive(NotificationCenter.default.publisher(for: .snapshotUpdated)) { _ in
            guard rebuildRule.snapshotArrived() else { return }
            dashboard.refreshAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview:
            OverviewView(appState: appState, dashboard: dashboard)
        case .agents:
            AgentsHistoryView(dashboard: dashboard)
        case .history:
            SessionHistoryView(appState: appState, dashboard: dashboard)
        case .insights:
            InsightsView(dashboard: dashboard)
        }
    }
}

// MARK: - Common chrome

struct DashboardHeader: View {
    let title: String
    /// A line under the title only where it says something the title does not
    /// (History's unit and its API-equivalent note); 3.0 drops the filler ones
    /// (liquid-glass spec § Removals).
    var subtitle: String? = nil
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
        // fits wins; the title always keeps its line, the subtitle wraps at the narrowest.
        ViewThatFits(in: .horizontal) {
            oneRow
            twoRows
            threeRows
        }
        .padding(.leading, DashboardShellLayout.columnLeading)
        .padding(.trailing, DashboardShellLayout.columnTrailing)
        .padding(.top, DashboardShellLayout.columnTop)
        .padding(.bottom, 12)
    }

    /// Only the title is rigid: it is two words and must never truncate. The subtitle is
    /// a sentence and wraps. When the whole block was rigid, the History subtitle was
    /// wider than the detail column at the 820 pt minimum, and the vertical-only scroll
    /// view clipped the rest of the tab instead.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(OMFont.dashboardTitle)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let subtitle {
                Text(subtitle)
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// The time range History and Agents chart over, on the 3.0 glass capsule (spec
/// § Components, "Segmented controls"). Short names and no logos; the window's number
/// keys stay off, as on the provider row.
struct RangePicker: View {
    @Binding var range: TimeRange

    nonisolated static let accessibilityName = "Time range"

    var body: some View {
        OMSegmentedControl(
            items: Self.items(for: TimeRange.allCases),
            selection: Binding(
                get: { range.rawValue },
                set: { range = Self.timeRange(forSegment: $0, current: range) }
            ),
            alwaysShowsTitles: true,
            keyboardShortcuts: false
        )
        // The header is a flexible HStack; without this the capsule would stretch
        // across whatever the title leaves free.
        .fixedSize()
        // The control names itself "Provider"; this one is not about a provider.
        .accessibilityLabel(Self.accessibilityName)
    }

    /// One segment per range, titled with its short name ("7d").
    nonisolated static func items(for ranges: [TimeRange]) -> [OMSegmentItem] {
        ranges.map { OMSegmentItem(id: $0.rawValue, title: $0.displayName) }
    }

    /// The range a segment stands for; an id no range answers to changes nothing.
    nonisolated static func timeRange(forSegment id: String, current: TimeRange) -> TimeRange {
        TimeRange(rawValue: id) ?? current
    }
}
