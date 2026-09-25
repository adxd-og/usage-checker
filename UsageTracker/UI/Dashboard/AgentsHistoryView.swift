import SwiftUI

/// The dashboard's Agents tab: how many sessions finished inside the selected range,
/// and what is running right now. Live rows come from `AgentSessionStore`; the count
/// comes from `agent-sessions.jsonl` via `DashboardState.agentRecords`. The finished
/// sessions themselves are listed in History (liquid-glass spec § Removals).
struct AgentsHistoryView: View {
    @ObservedObject var dashboard: DashboardState
    @ObservedObject private var agents = AgentSessionStore.shared

    nonisolated static let sourceKey = "agentsHistorySource"

    @AppStorage(AgentsHistoryView.sourceKey) private var storedSource: String = "all"

    /// nil = every source. An unknown stored value (a provider that never shipped, a
    /// hand-edited plist) reads as All rather than filtering everything away.
    nonisolated static func selectedSource(_ stored: String) -> AgentSource? {
        stored == "all" ? nil : AgentSource(rawValue: stored)
    }

    /// What `.task(id:)` watches. The session count alone misses every same-count
    /// transition — one session ending as another starts, or a session archived and
    /// revived by `claude --resume` — and each of those appends to the log.
    nonisolated static func historyReloadKey(sessions: Int, lastEventAt: Date?) -> String {
        "\(sessions)-\(lastEventAt?.timeIntervalSince1970 ?? 0)"
    }

    private var source: AgentSource? { Self.selectedSource(storedSource) }

    private var liveSessions: [AgentSession] {
        guard let source else { return agents.sessions }
        return agents.sessions.filter { $0.source == source }
    }

    var body: some View {
        let summary = AgentHistorySummary.make(
            records: dashboard.agentRecords, source: source, range: dashboard.range, now: Date()
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardHeader(
                    title: AgentsCopy.title,
                    trailing: AnyView(headerControls),
                    showsServicePicker: false
                )

                VStack(alignment: .leading, spacing: AgentsLayout.cardSpacing) {
                    AgentsStatsCard(tiles: AgentsStatsRules.tiles(summary))

                    AgentsSection(
                        sessions: liveSessions,
                        grouped: true,
                        // The dashboard never nags about hooks — Settings → Agents owns that.
                        hooksInstalled: true,
                        title: "Live",
                        // The page is already a ScrollView; a second one inside it would
                        // eat the wheel and hide rows behind a cap the window doesn't need.
                        maxListHeight: .infinity,
                        onEnable: {}
                    )
                }
                // The mockup's column, whose side gutters the header already sits on.
                .padding(.top, AgentsLayout.headerGap)
                .padding(.leading, DashboardShellLayout.columnLeading)
                .padding(.trailing, DashboardShellLayout.columnTrailing)
                .padding(.bottom, AgentsLayout.columnBottom)
            }
        }
        // A session ending is what appends to the log, so the live store changing is
        // the cheapest signal that the count is stale. Also runs on first appearance.
        .task(id: Self.historyReloadKey(sessions: agents.sessions.count, lastEventAt: agents.lastEventAt)) {
            await dashboard.refreshAgentHistory()
        }
    }

    /// All, then one segment per agent source; the ids are what `selectedSource` reads.
    nonisolated static let sourceItems = [
        OMSegmentItem(id: "all", title: "All"),
        OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude"),
        OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex", sfFallback: "terminal"),
    ]

    /// The mockup's title row: the source filter, then the range, 12 pt apart, in the
    /// header's trailing slot (its provider row stays hidden: this tab is not about one
    /// provider). The filter keeps ⌘1–⌘3 (All / Claude / Codex), as in 2.7; the range
    /// picker has no number keys.
    private var headerControls: some View {
        HStack(spacing: AgentsLayout.headerControlsSpacing) {
            OMSegmentedControl(
                items: Self.sourceItems,
                selection: $storedSource,
                accessibilityLabel: AgentsCopy.sourcePickerName
            )
            // The header is a flexible HStack; without this the capsule would stretch
            // across whatever the title leaves free.
            .fixedSize()
            RangePicker(range: $dashboard.range)
        }
    }
}
