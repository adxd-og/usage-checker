import SwiftUI

/// One "Needs you" / "Working" / … block, in the order the All tab lists them.
struct AgentGroup: Identifiable, Equatable {
    let state: AgentState
    let sessions: [AgentSession]
    var id: String { state.rawValue }
}

/// What the popover's agents list tells its host (popover height budget spec
/// 2026-10-27): the list's frame as shown (its content, up to the cap) and the
/// height of its first two rows with the hairline between them, the least the
/// host may cap it to (`AgentsSection.minimumListHeight`).
struct AgentsListGeometry: Equatable, Sendable {
    let shownHeight: CGFloat
    let minimumHeight: CGFloat
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
    /// Called with the list's shown height and its two-row floor whenever either
    /// changes, and with nil when the section has no sessions. The popover sizes the
    /// list to the screen from it (`PopoverHeightRules`); nil everywhere else.
    var onListGeometry: ((AgentsListGeometry?) -> Void)? = nil
    let onEnable: () -> Void

    nonisolated static let defaultTitle = "Agents"
    /// About five rows. Past this the list scrolls instead of growing the popover.
    nonisolated static let defaultMaxListHeight: CGFloat = 260
    /// The heading and the link sit 4 pt in from the card's edge.
    nonisolated static let headerInset: CGFloat = 4
    nonisolated static let surface: OMPopoverSurface = .group

    /// The 1 pt line between two rows.
    nonisolated static let hairlineHeight: CGFloat = 1
    /// Used only until the list has measured itself once, so the section never
    /// flashes at 1 pt on the first frame; also what a row not measured yet counts
    /// as in the popover's two-row floor (`minimumListHeight`).
    nonisolated static let estimatedRowHeight: CGFloat = 54

    @State private var listHeight: CGFloat = 0
    /// The list's frame as last laid out: its content, up to `maxListHeight`.
    @State private var shownHeight: CGFloat = 0
    /// Each row's height as last laid out, by session id, so the first two are known
    /// whichever sessions lead the list.
    @State private var rowHeights: [String: CGFloat] = [:]

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
        // A section with no sessions has no list to size: the host drops the last report.
        .onChange(of: sessions.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { onListGeometry?(nil) }
        }
        // The report, published whenever it changes and only then (ruling R2): a new
        // shown height, a row that measured itself again, or rows that moved into first
        // place without measuring again.
        .onChange(of: listGeometry, initial: true) { _, geometry in
            if let geometry { onListGeometry?(geometry) }
        }
        // The heights of sessions that have gone are never read again.
        .onChange(of: sessions.map(\.id)) { _, ids in
            rowHeights = rowHeights.filter { ids.contains($0.key) }
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
                        // Each row's own height, for the popover's two-row floor (C4); the
                        // report goes out through `listGeometry` (R2).
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            rowHeights[session.id] = height
                        }
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
        // The frame as shown, from the layout pass that produced it: the pass in which
        // the popover measures its own height, so the host's `popover − list` stays put
        // when the cap moves (spec 2026-10-27). Sent from here at once as well as through
        // `listGeometry`'s `.onChange`: through `.onChange` alone it would lag the
        // popover's height by an update and the cap would flip for ever (plan D2). The
        // re-send that follows carries the same value and is dropped by the host.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            shownHeight = height
            if let geometry = listGeometry { onListGeometry?(geometry) }
        }
        .scrollIndicators(listHeight > maxListHeight ? .automatic : .never)
        .scrollDisabled(listHeight <= maxListHeight)
        // A scrolled row never paints past the card's corners.
        .clipShape(OMCornerShape(Self.surface.corner))
    }

    /// The 1 pt line between rows, inset to the rows' text edge.
    private var hairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: Self.hairlineHeight)
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
        CGFloat(sessions.count) * Self.estimatedRowHeight + CGFloat(max(0, sessions.count - 1)) * Self.hairlineHeight
    }

    /// The list's report as of this body (ruling R2): its shown height and the floor of
    /// the rows that lead it now. nil while there is nothing to list or the frame has
    /// not been laid out yet, so a section that just appeared never wipes a report the
    /// host already holds.
    private var listGeometry: AgentsListGeometry? {
        guard !sessions.isEmpty, shownHeight > 0 else { return nil }
        return AgentsListGeometry(
            shownHeight: shownHeight,
            minimumHeight: Self.minimumListHeight(
                rowIDs: Self.rows(sessions, grouped: grouped).map(\.id),
                rowHeights: rowHeights
            )
        )
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

    /// The least the popover may cap the list to (popover height budget spec
    /// 2026-10-27, Q2, plan rulings C4 and R2): the first two rows in list order as
    /// measured, with the hairline between them, so the second row is never clipped;
    /// the first row alone when it is the only one; 54 pt for a row not measured yet.
    nonisolated static func minimumListHeight(rowIDs: [String], rowHeights: [String: CGFloat]) -> CGFloat {
        guard let firstID = rowIDs.first else { return 0 }
        let first = rowHeights[firstID] ?? estimatedRowHeight
        guard rowIDs.count > 1 else { return first }
        return first + hairlineHeight + (rowHeights[rowIDs[1]] ?? estimatedRowHeight)
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
