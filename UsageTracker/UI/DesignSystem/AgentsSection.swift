import SwiftUI

/// One "Needs you" / "Working" / … block, in the order the All tab lists them.
struct AgentGroup: Identifiable, Equatable {
    let state: AgentState
    let sessions: [AgentSession]
    var id: String { state.rawValue }
}

/// The popover's agent list (`Main.dc.html`): a sentence-case heading with the session
/// count over one group card of rows split by hairlines. On the All tab (`grouped`) the
/// rows run in state order — needs you, working, done, idle — with provider logos,
/// because rows from every provider mix there; on a provider tab (flat) whatever needs
/// you comes first, then the most recent. Each row says its own state, so there are no
/// uppercase group headings (spec § Principles 3). The list is the only part of the
/// popover that scrolls — the header, segments and footer must not move when an agent
/// starts a long run.
struct AgentsSection: View {
    let sessions: [AgentSession]
    let grouped: Bool
    let hooksInstalled: Bool
    var title: String = AgentsSection.defaultTitle
    /// `.infinity` means "grow to fit and never scroll" — what a host that already
    /// scrolls (the dashboard page) needs, since a scroll view inside a scroll view
    /// swallows the wheel.
    var maxListHeight: CGFloat = AgentsSection.defaultMaxListHeight
    let onEnable: () -> Void

    nonisolated static let defaultTitle = "Agents"
    /// About five rows. Past this the list scrolls instead of growing the popover.
    nonisolated static let defaultMaxListHeight: CGFloat = 260
    /// The heading and the link sit 4 pt in from the card's edge.
    nonisolated static let headerInset: CGFloat = 4
    nonisolated static let surface: OMPopoverSurface = .group

    /// Used only until the list has measured itself once, so the section never
    /// flashes at 1 pt on the first frame.
    nonisolated private static let estimatedRowHeight: CGFloat = 54

    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            OMSectionHeader(title: title, trailing: sessions.isEmpty ? nil : Self.sessionsCaption(sessions.count))
                .padding(.horizontal, Self.headerInset)
            Group {
                if sessions.isEmpty {
                    emptyRow
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .popoverSurface(Self.surface)
            if !hooksInstalled {
                Button("Enable precise status", action: onEnable)
                    .buttonStyle(.omLink)
                    .help("Install Omelette's hooks so states are exact instead of guessed from log files")
                    .padding(.horizontal, Self.headerInset)
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                let rows = Self.rows(sessions, grouped: grouped)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { hairline }
                    row(session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Self-sizing scroll view: measure the content, then take exactly
                // that height up to the cap. `.task(id:)` rather than a preference
                // key so the write to @State stays on the main actor under Swift 6.
                GeometryReader { proxy in
                    Color.clear.task(id: proxy.size.height) { listHeight = proxy.size.height }
                }
            }
        }
        // With an infinite cap all three collapse to "exactly the content height,
        // no indicators, no scrolling" — the list just grows.
        .frame(height: min(listHeight > 0 ? listHeight : estimatedHeight, maxListHeight))
        .scrollIndicators(listHeight > maxListHeight ? .automatic : .never)
        .scrollDisabled(listHeight <= maxListHeight)
        // A scrolled row never paints past the card's corners.
        .clipShape(OMCornerShape(Self.surface.corner))
    }

    /// The 1 pt line between rows, inset to the rows' text edge.
    private var hairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: 1)
            .padding(.horizontal, OMAgentRow.horizontalPadding)
    }

    /// Both list shapes go through here, so the grouped All tab and the flat
    /// provider tab get the same buttons from one place.
    private func row(_ session: AgentSession) -> some View {
        OMAgentRow(
            session: session,
            showsProviderIcon: grouped,
            onAllow: { Self.answer(session, .allow) },
            onDeny: { Self.answer(session, .deny) },
            action: { SessionActivator.jump(to: session) }
        )
        .opacity(Self.rowOpacity(session.state))
    }

    /// A row can outlive the request it was drawn for — the hold expires, or you
    /// switched back to the terminal — so the id is re-read at click time and the
    /// broker ignores an id it has already answered.
    static func answer(_ session: AgentSession, _ decision: PermissionDecision) {
        guard let id = session.pendingPermissionID else { return }
        PermissionBroker.shared.answer(id: id, decision)
    }

    private var emptyRow: some View {
        Text("No agent sessions")
            .font(.system(size: 12.5))
            .foregroundStyle(.om(.secondary))
            .padding(.horizontal, OMAgentRow.horizontalPadding)
            .padding(.vertical, OMAgentRow.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var estimatedHeight: CGFloat {
        CGFloat(sessions.count) * Self.estimatedRowHeight + CGFloat(max(0, sessions.count - 1))
    }
}

// MARK: - Grouping and ordering (pure, unit-tested)

extension AgentsSection {
    /// Non-empty groups in state order (needs you → working → done → idle); the
    /// most recently active session leads each group.
    nonisolated static func groups(_ sessions: [AgentSession]) -> [AgentGroup] {
        AgentState.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { state in
                let members = sessions
                    .filter { $0.state == state }
                    .sorted { $0.lastEventAt > $1.lastEventAt }
                return members.isEmpty ? nil : AgentGroup(state: state, sessions: members)
            }
    }

    /// Flat list for a provider tab: anything waiting for you first, then most
    /// recent activity first.
    nonisolated static func flat(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            let aWaits = a.state == .needsYou
            let bWaits = b.state == .needsYou
            if aWaits != bWaits { return aWaits }
            return a.lastEventAt > b.lastEventAt
        }
    }

    /// The rows in list order. All tab: every state group in turn, most recent first
    /// within each — the order the headings used to carry, now one card with the state
    /// on each row. Provider tab: `flat`.
    nonisolated static func rows(_ sessions: [AgentSession], grouped: Bool) -> [AgentSession] {
        grouped ? groups(sessions).flatMap(\.sessions) : flat(sessions)
    }

    nonisolated static func sessionsCaption(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    /// Finished work stays readable but stops competing with live rows.
    nonisolated static func rowOpacity(_ state: AgentState) -> Double {
        (state == .done || state == .idle) ? 0.7 : 1
    }
}

#if DEBUG
#Preview("Agents — grouped, light") {
    AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
        .padding().frame(width: 360)
}

#Preview("Agents — grouped, dark") {
    AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
        .padding().frame(width: 360).preferredColorScheme(.dark)
}

#Preview("Agents — flat provider tab") {
    AgentsSection(
        sessions: AgentPreviewData.mixed.filter { $0.source == .claude },
        grouped: false,
        hooksInstalled: true,
        onEnable: {}
    )
    .padding().frame(width: 360)
}

#Preview("Agents — empty, hooks missing") {
    AgentsSection(sessions: [], grouped: true, hooksInstalled: false, onEnable: {})
        .padding().frame(width: 360)
}

#Preview("Agents — long list scrolls") {
    AgentsSection(
        sessions: AgentPreviewData.mixed + (1...6).map {
            AgentPreviewData.session("Project \($0)", .idle, minutes: Double($0) * 7)
        },
        grouped: true,
        hooksInstalled: true,
        onEnable: {}
    )
    .padding().frame(width: 360)
}
#endif
