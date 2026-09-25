import SwiftUI

/// The Agents tab's Live card (`Dashboard-Agents(-Light).dc.html`; liquid-glass spec
/// § Screens, "Agents", and § Components, "Agent row (dashboard)"). It shows "Live" and
/// how many sessions are running, then one row per session: the 3.0 agent row at the
/// dashboard's size, with the provider logo and a state dot at its bottom-right, Needs
/// you in the accent, Allow filled and Deny on glass. Hairlines split the rows. The card
/// is full width, and the page scrolls, so the list never does. Finished sessions are
/// listed in History, which the header's "All sessions in History ›" opens.
struct AgentsLiveCard: View {
    let sessions: [AgentSession]
    /// The link's action. The host owns it: it knows the source filter, and the provider
    /// switch goes through `DashboardState` (`AgentsLinkRules`).
    let onShowHistory: () -> Void

    /// Rows from both sources can mix here (the filter's All), so each wears its logo.
    nonisolated static let showsProviderIcon = true

    /// The mockup draws these rows a size up from the popover's (28 pt logo, 13.5 pt title).
    nonisolated static let rowMetrics: OMAgentRowMetrics = .dashboard

    /// State order (needs you, working, done, idle), most recent first inside each
    /// state: the popover's All tab, whichever source the filter shows.
    nonisolated static func rows(_ sessions: [AgentSession]) -> [AgentSession] {
        AgentsSection.rows(sessions, grouped: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AgentsLayout.cardHorizontalPadding)
            Color.clear
                .frame(height: AgentsLayout.liveHeaderGap)
                .accessibilityHidden(true)
            list
                .padding(.horizontal, AgentsLayout.liveRowsInset)
        }
        .padding(.top, AgentsLayout.cardVerticalPadding)
        .padding(.bottom, AgentsLayout.liveBottomPadding)
        .dashboardCard(padding: 0)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentsLayout.liveTitleCountSpacing) {
            Text(AgentsCopy.liveTitle)
                .font(.system(size: AgentsLayout.liveTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .accessibilityAddTraits(.isHeader)
            if let count = AgentsCopy.liveCount(sessions.count) {
                Text(count)
                    .font(.system(size: AgentsLayout.liveCountSize))
                    .monospacedDigit()
                    .foregroundStyle(.om(.secondary))
            }
            Spacer(minLength: OMSpacing.m)
            Button(AgentsCopy.historyLink, action: onShowHistory)
                .buttonStyle(.omLink)
        }
    }

    @ViewBuilder
    private var list: some View {
        if sessions.isEmpty {
            Text(AgentsCopy.liveEmpty)
                .font(.system(size: AgentsLayout.liveCountSize))
                .foregroundStyle(.om(.secondary))
                .padding(.horizontal, OMAgentRow.horizontalPadding)
                .padding(.vertical, AgentsLayout.liveRowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.rows(sessions).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { hairline }
                    row(session)
                }
            }
        }
    }

    /// The 1 pt line between rows, on the rows' text edge: the card's 24 pt inset.
    private var hairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: 1)
            .padding(.horizontal, OMAgentRow.horizontalPadding)
    }

    /// Allow and Deny go through `AgentsSection.answer`, the popover's answer rule.
    private func row(_ session: AgentSession) -> some View {
        OMAgentRow(
            session: session,
            showsProviderIcon: Self.showsProviderIcon,
            metrics: Self.rowMetrics,
            onAllow: { AgentsSection.answer(session, .allow) },
            onDeny: { AgentsSection.answer(session, .deny) },
            action: { SessionActivator.jump(to: session) }
        )
        .padding(.vertical, AgentsLayout.liveRowOuterPadding)
        .opacity(AgentsSection.rowOpacity(session.state))
    }
}

#if DEBUG
#Preview("Live card — dark") {
    AgentsLiveCard(sessions: AgentPreviewData.mixed, onShowHistory: {})
        .padding()
        .frame(width: 900)
        .preferredColorScheme(.dark)
}

#Preview("Live card — light") {
    AgentsLiveCard(sessions: AgentPreviewData.mixed, onShowHistory: {})
        .padding()
        .frame(width: 900)
}

#Preview("Live card — nothing running") {
    AgentsLiveCard(sessions: [], onShowHistory: {})
        .padding()
        .frame(width: 900)
}
#endif
