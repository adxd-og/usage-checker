import SwiftUI

/// One "Needs you" / "Working" / … block of the grouped list.
struct AgentGroup: Identifiable, Equatable {
    let state: AgentState
    let sessions: [AgentSession]
    var id: String { state.rawValue }
}

/// The popover's agent list. `grouped` (All tab) puts rows under status
/// headings and shows provider logos, because rows from every provider mix
/// there; flat (provider tab) is one list of state dots with whatever needs you
/// first. The list is the only part of the popover that scrolls — the header,
/// segments and footer must not move when an agent starts a long run.
struct AgentsSection: View {
    let sessions: [AgentSession]
    let grouped: Bool
    let hooksInstalled: Bool
    var title: String = "Agents"
    /// `.infinity` means "grow to fit and never scroll" — what a host that already
    /// scrolls (the dashboard page) needs, since a scroll view inside a scroll view
    /// swallows the wheel.
    var maxListHeight: CGFloat = AgentsSection.defaultMaxListHeight
    let onEnable: () -> Void

    /// About five rows, or four rows with their group headings — the mockup's
    /// layout. Past this the list scrolls instead of growing the popover.
    nonisolated static let defaultMaxListHeight: CGFloat = 260

    /// Used only until the list has measured itself once, so the section never
    /// flashes at 1 pt on the first frame.
    nonisolated private static let estimatedRowHeight: CGFloat = 49
    nonisolated private static let estimatedGroupLabelHeight: CGFloat = 27

    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            OMSectionHeader(title: title, trailing: sessions.isEmpty ? nil : Self.sessionsCaption(sessions.count))
            if sessions.isEmpty {
                emptyRow
            } else {
                list
            }
            if !hooksInstalled {
                Button("Enable precise status", action: onEnable)
                    .buttonStyle(.link)
                    .font(OMFont.caption)
                    .help("Install Omelette's hooks so states are exact instead of guessed from log files")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: OMSpacing.xs + 1) {
                if grouped {
                    ForEach(Self.groups(sessions)) { group in
                        Text(Self.groupTitle(group.state))
                            .font(OMFont.micro)
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(Self.groupColor(group.state))
                            .padding(.top, OMSpacing.xs)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.sessions) { row($0) }
                    }
                } else {
                    ForEach(Self.flat(sessions)) { row($0) }
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
    private static func answer(_ session: AgentSession, _ decision: PermissionDecision) {
        guard let id = session.pendingPermissionID else { return }
        PermissionBroker.shared.answer(id: id, decision)
    }

    private var emptyRow: some View {
        Text("No agent sessions")
            .font(OMFont.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
    }

    private var estimatedHeight: CGFloat {
        let labels = grouped ? Self.groups(sessions).count : 0
        return CGFloat(sessions.count) * Self.estimatedRowHeight + CGFloat(labels) * Self.estimatedGroupLabelHeight
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

    nonisolated static func sessionsCaption(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    nonisolated static func groupTitle(_ state: AgentState) -> String {
        switch state {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// Only the live states are coloured — a green "Done" heading competes with
    /// the amber one that actually needs the user.
    nonisolated static func groupColor(_ state: AgentState) -> Color {
        switch state {
        case .needsYou: return OMAgentColor.needsYou
        case .working: return OMAgentColor.working
        case .done, .idle: return .secondary
        }
    }

    /// Finished work stays readable but stops competing with live rows.
    nonisolated static func rowOpacity(_ state: AgentState) -> Double {
        (state == .done || state == .idle) ? 0.7 : 1
    }
}

#if DEBUG
#Preview("Agents — grouped, light") {
    AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
        .padding().frame(width: 328)
}

#Preview("Agents — grouped, dark") {
    AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
        .padding().frame(width: 328).preferredColorScheme(.dark)
}

#Preview("Agents — flat provider tab") {
    AgentsSection(
        sessions: AgentPreviewData.mixed.filter { $0.source == .claude },
        grouped: false,
        hooksInstalled: true,
        title: "Claude agents",
        onEnable: {}
    )
    .padding().frame(width: 328)
}

#Preview("Agents — empty, hooks missing") {
    AgentsSection(sessions: [], grouped: true, hooksInstalled: false, onEnable: {})
        .padding().frame(width: 328)
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
    .padding().frame(width: 328)
}
#endif
