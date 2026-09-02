import SwiftUI

/// The dashboard's Agents tab: what is running right now, and what has finished
/// inside the selected range. Live rows come from `AgentSessionStore`; the history
/// comes from `agent-sessions.jsonl` via `DashboardState.agentRecords`.
struct AgentsHistoryView: View {
    @ObservedObject var dashboard: DashboardState
    @ObservedObject private var agents = AgentSessionStore.shared

    nonisolated static let sourceKey = "agentsHistorySource"

    @AppStorage(AgentsHistoryView.sourceKey) private var storedSource: String = "all"

    /// Only used for one caption in the empty state, so it is read once per
    /// appearance off the main thread (same pattern as `PopoverView`). Starts `true`
    /// so the caption never flashes before the read lands.
    @State private var claudeHooksInstalled = true

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
    private var calendar: Calendar { Calendar.current }

    private var liveSessions: [AgentSession] {
        guard let source else { return agents.sessions }
        return agents.sessions.filter { $0.source == source }
    }

    var body: some View {
        // One clock for the whole pass: the tiles and the day titles must agree on
        // where "today" ends.
        let now = Date()
        let summary = AgentHistorySummary.make(
            records: dashboard.agentRecords, source: source, range: dashboard.range, now: now
        )
        let days = AgentHistorySummary.days(
            records: dashboard.agentRecords, source: source,
            range: dashboard.range, now: now, calendar: calendar
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: "Agents",
                    subtitle: "Live sessions and run history",
                    trailing: AnyView(RangePicker(range: $dashboard.range)),
                    showsServicePicker: false
                )

                OMSegmentedControl(items: Self.sourceItems, selection: $storedSource)
                    .frame(width: 260)
                    .padding(.horizontal, 24)

                AgentsSummaryStrip(summary: summary)
                    .padding(.horizontal, 24)

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
                .padding(.horizontal, 24)

                history(days: days, now: now)
                    .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        // A session ending is what appends to the log, so the live store changing is
        // the cheapest signal that the history is stale. Also runs on first appearance.
        .task(id: Self.historyReloadKey(sessions: agents.sessions.count, lastEventAt: agents.lastEventAt)) {
            await dashboard.refreshAgentHistory()
        }
        .task { await refreshHookStatus() }
    }

    private static let sourceItems = [
        OMSegmentItem(id: "all", title: "All"),
        OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude"),
        OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex", sfFallback: "terminal"),
    ]

    @ViewBuilder
    private func history(days: [(day: Date, records: [AgentSessionRecord])], now: Date) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            OMSectionHeader(
                title: "History",
                trailing: days.isEmpty ? nil : AgentsSection.sessionsCaption(days.reduce(0) { $0 + $1.records.count })
            )
            if days.isEmpty {
                emptyHistory
            } else {
                ForEach(days, id: \.day) { group in
                    Text(AgentHistorySummary.dayTitle(group.day, now: now, calendar: calendar))
                        .font(OMFont.micro)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.top, OMSpacing.xs)
                        .accessibilityAddTraits(.isHeader)
                    // Keyed on position, not `record.id`: a session archived by
                    // `pruneStale` and archived again after `claude --resume` writes
                    // the same id twice, and duplicate ForEach ids drop rows.
                    ForEach(Array(group.records.enumerated()), id: \.offset) { _, record in
                        OMAgentHistoryRow(record: record)
                    }
                }
            }
        }
    }

    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            Text("No finished sessions in this range")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            if !claudeHooksInstalled {
                Text("Hooks give exact durations")
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
    }

    private func refreshHookStatus() async {
        let settingsURL = AgentPaths.claudeSettingsURL
        let helperPath = AgentPaths.helperSymlinkURL.path
        let status = await Task.detached(priority: .utility) {
            AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helperPath)
        }.value
        claudeHooksInstalled = status == .installed
    }
}

/// The four numbers above the lists: how many sessions, how long they ran in total,
/// how often they stopped to ask, and where the work happened.
private struct AgentsSummaryStrip: View {
    let summary: AgentHistorySummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile(label: "Sessions", value: "\(summary.sessions)", sub: nil)
            tile(label: "Agent time", value: AgentHistorySummary.duration(summary.agentTime), sub: nil)
            tile(label: "Approval requests", value: "\(summary.approvalsWaited)", sub: nil)
            tile(
                label: "Busiest project",
                value: summary.busiestProject?.name ?? "—",
                sub: summary.busiestProject.map { AgentsSection.sessionsCaption($0.sessions) }
            )
        }
    }

    private func tile(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            Text(label)
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(OMFont.heroNumeral)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            // A blank line that only keeps the four tiles the same height — there is
            // nothing here to read out.
            Text(sub ?? " ")
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
                .opacity(sub == nil ? 0 : 1)
                .accessibilityHidden(sub == nil)
        }
        .dashboardCard(padding: 12)
        // One stop per tile: "Sessions, 12" rather than three separate elements.
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
@MainActor
private func summaryStripPreview() -> some View {
    AgentsSummaryStrip(summary: AgentHistorySummary(
        sessions: 12,
        agentTime: 41_520,
        approvalsWaited: 7,
        busiestProject: (name: "Usage tracker", sessions: 5)
    ))
    .padding()
    .frame(width: 780)
}

#Preview("Agents summary — light") { summaryStripPreview() }
#Preview("Agents summary — dark") { summaryStripPreview().preferredColorScheme(.dark) }
#Preview("Agents summary — empty") {
    AgentsSummaryStrip(summary: AgentHistorySummary(sessions: 0, agentTime: 0, approvalsWaited: 0, busiestProject: nil))
        .padding()
        .frame(width: 780)
}
#endif
