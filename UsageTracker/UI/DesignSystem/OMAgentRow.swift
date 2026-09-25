import SwiftUI

/// Pure text rules for an agent row. They live outside the view so the wording
/// and the clock arithmetic are unit-tested instead of eyeballed in a preview.
enum AgentRowText {
    /// What the agent is doing, in one line: the tool summary when we have one,
    /// otherwise the state itself. Log-scanned sessions get "≈ " — their state is
    /// inferred from file mtimes, not reported by a hook, and the row should not
    /// pretend otherwise.
    static func subtitle(for session: AgentSession, showsState: Bool = false) -> String {
        let activity = session.activity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text: String
        if activity.isEmpty {
            text = statePhrase(session.state)
        } else if showsState {
            // Provider tab: no group heading says the state, so the row does.
            text = "\(statePhrase(session.state)) · \(activity)"
        } else {
            text = activity
        }
        return session.isApproximate ? "≈ \(text)" : text
    }

    static func statePhrase(_ state: AgentState) -> String {
        switch state {
        case .needsYou: return "Needs approval"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// How long the session has been in its current state. Live states read as a
    /// running duration ("14m", "2h 05m"); finished ones read as a moment in the
    /// past ("5m ago") because nothing is ticking any more.
    static func elapsed(since: Date, now: Date = Date(), state: AgentState) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let isPast = isFinished(state)
        if seconds < 60 { return isPast ? "just now" : "now" }
        let minutes = Int(seconds / 60)
        let base: String
        if minutes < 60 {
            base = "\(minutes)m"
        } else if minutes < 24 * 60 {
            base = String(format: "%dh %02dm", minutes / 60, minutes % 60)
        } else {
            base = "\(minutes / (24 * 60))d"
        }
        return isPast ? "\(base) ago" : base
    }

    /// VoiceOver reads "14m" as "fourteen m", so the spoken form spells the units.
    static func spokenElapsed(since: Date, now: Date = Date(), state: AgentState) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let isPast = isFinished(state)
        if seconds < 60 { return isPast ? "just now" : "for less than a minute" }
        let minutes = Int(seconds / 60)
        let phrase: String
        if minutes < 60 {
            phrase = plural(minutes, "minute")
        } else if minutes < 24 * 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            phrase = rest == 0 ? plural(hours, "hour") : "\(plural(hours, "hour")) \(plural(rest, "minute"))"
        } else {
            phrase = plural(minutes / (24 * 60), "day")
        }
        return isPast ? "\(phrase) ago" : "for \(phrase)"
    }

    static func sourceName(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Whether the row offers Allow / Deny. Both sources can be held since 2.4 —
    /// Codex has its own `PermissionRequest` hook — so what decides it is the id
    /// alone: a blank id is not an id, and buttons that answer nothing are worse
    /// than no buttons. `source` stays in the signature for the call sites and for
    /// the day one of them needs it again.
    static func permissionButtonsVisible(pendingPermissionID: String?, source: AgentSource) -> Bool {
        let id = pendingPermissionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !id.isEmpty
    }

    /// Whether the row offers the chevron that expands the full text. A detail that
    /// only repeats the summary is already nil by the time it gets here
    /// (`AgentToolSummary`), so this is the blank check and nothing more.
    static func detailIsExpandable(_ activityDetail: String?) -> Bool {
        !(activityDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// What clicking the row does. A question or a plan can only be answered where it
    /// was asked, so the row says so instead of implying Omelette can take the answer.
    /// With a request held *and* a question open — Codex asks permission to ask —
    /// Allow only lets the agent put the question up; the answer is still typed in
    /// the terminal, and the row has to say which of the two the buttons do.
    static func jumpHelp(for session: AgentSession) -> String {
        guard session.attention != nil else { return "Jump to \(session.projectName)" }
        guard session.pendingPermissionID == nil else {
            return "Allow lets the agent ask; then answer in the terminal"
        }
        return "Click to go to the terminal and answer"
    }

    /// One sentence carrying everything the row shows visually: project,
    /// provider, state, activity, and how long it has been that way.
    static func accessibilityLabel(for session: AgentSession, now: Date = Date()) -> String {
        var parts = [session.projectName, sourceName(session.source), statePhrase(session.state)]
        let activity = session.activity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !activity.isEmpty {
            parts.append(session.isApproximate ? "approximately \(activity)" : activity)
        }
        parts.append(spokenElapsed(since: session.stateSince, now: now, state: session.state))
        return parts.joined(separator: ", ")
    }

    /// The state on the title line, after the project and in the accent: only Needs
    /// you, the one state that asks for the user (`Main.dc.html`: "test · Needs you").
    /// Every other state is the dot's colour.
    static func titleBadge(_ state: AgentState) -> String? {
        state == .needsYou ? "Needs you" : nil
    }

    /// The row's second line. A provider tab has no logo to set the state against, so
    /// the line says it ("Done · Probe whether…") — except Needs you, which the title
    /// already says.
    static func rowSubtitle(for session: AgentSession, providerTab: Bool) -> String {
        subtitle(for: session, showsState: providerTab && titleBadge(session.state) == nil)
    }

    /// The state dot: yolk when it needs you, blue while it works, green when the turn
    /// is done, muted when idle.
    static func dotToken(_ state: AgentState) -> OMColorToken {
        switch state {
        case .needsYou: .accent
        case .working: .working
        case .done: .ok
        case .idle: .muted
        }
    }

    /// The 3 pt halo a live dot wears: the accent at 28 % (the mockups'
    /// `color-mix(accent 28%)`, the focus-ring value) and the working blue at 25 %.
    static func haloToken(_ state: AgentState) -> OMColorToken? {
        switch state {
        case .needsYou: .focusRing
        case .working: .workingHalo
        case .done, .idle: nil
        }
    }

    private static func isFinished(_ state: AgentState) -> Bool {
        state == .done || state == .idle
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

/// The two sizes the 3.0 mockups draw an agent row at (liquid-glass spec § Components,
/// "Agent row (dashboard)"). The popover's (`Main.dc.html`) is the default. The
/// dashboard's Live card (`Dashboard-Agents(-Light).dc.html`) opts into one a size up.
/// Paddings, spacing and the buttons are the same in both.
struct OMAgentRowMetrics: Equatable, Sendable {
    /// The provider logo's box, which the state badge sits on.
    let logoSide: CGFloat
    let badgeDiameter: CGFloat
    let titleSize: CGFloat
    /// The status line and the elapsed time.
    let subtitleSize: CGFloat

    /// The logo inside its box: 2 pt smaller, as the popover has always drawn it.
    var iconSize: CGFloat { logoSide - 2 }

    /// 20 pt logo, 8 pt badge, 13 / 11.5 pt text: the row as it was before metrics.
    static let popover = OMAgentRowMetrics(
        logoSide: 20,
        badgeDiameter: OMAgentRow.badgeDiameter,
        titleSize: OMAgentRow.titleSize,
        subtitleSize: OMAgentRow.subtitleSize
    )

    /// 28 pt logo, 10 pt badge, 13.5 / 12.5 pt text.
    static let dashboard = OMAgentRowMetrics(logoSide: 28, badgeDiameter: 10, titleSize: 13.5, subtitleSize: 12.5)
}

/// One agent session (`Main.dc.html`'s agents card). The leading mark is the provider
/// logo with a state dot at its bottom-right on the All tab and the dashboard, where
/// rows from every provider mix, and the state dot alone — haloed while live — on a
/// provider tab, where the provider is already the tab. The title says Needs you in
/// the accent. The row's summary line is a button: clicking it jumps to that session.
/// A session with a held permission request grows a second line carrying **Allow**,
/// the one filled accent control, and **Deny** on glass — which is why the button is
/// the line and not the whole row.
struct OMAgentRow: View {
    let session: AgentSession
    var showsProviderIcon: Bool = true
    /// The popover's size unless the host opts into the dashboard's (`OMAgentRowMetrics`).
    var metrics: OMAgentRowMetrics = OMAgentRow.defaultMetrics
    /// Called by the row's **Allow** / **Deny**. Defaults do nothing so previews and
    /// any host that does not deal in permissions can ignore them. They precede
    /// `action`, which is why every call site passes `action:` by name: an unlabeled
    /// trailing closure would be matched against `onAllow` first.
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Metrics (`Main.dc.html`, `Popover-Claude.dc.html`)

    nonisolated static let horizontalPadding: CGFloat = 14
    nonisolated static let verticalPadding: CGFloat = 11
    /// Between the summary line, the detail block and the buttons.
    nonisolated static let lineSpacing: CGFloat = 10
    nonisolated static let leadingSpacing: CGFloat = 11
    nonisolated static let dotDiameter: CGFloat = 8
    nonisolated static let haloWidth: CGFloat = 3
    nonisolated static let badgeDiameter: CGFloat = 8
    /// The ring in the window colour that cuts a badge out of its logo.
    nonisolated static let badgeRing: CGFloat = 2
    nonisolated static let titleSize: CGFloat = 13
    nonisolated static let subtitleSize: CGFloat = 11.5
    /// Every host but the dashboard's Live card.
    nonisolated static let defaultMetrics: OMAgentRowMetrics = .popover

    /// The leading mark's width: the logo's box (20 pt in the popover), or the 8 pt dot.
    nonisolated static func leadingWidth(showsProviderIcon: Bool, metrics: OMAgentRowMetrics = .popover) -> CGFloat {
        showsProviderIcon ? metrics.logoSide : dotDiameter
    }

    /// Where the detail block and the buttons start: under the text, past the mark.
    nonisolated static func textInset(showsProviderIcon: Bool, metrics: OMAgentRowMetrics = .popover) -> CGFloat {
        leadingWidth(showsProviderIcon: showsProviderIcon, metrics: metrics) + leadingSpacing
    }

    private var showsPermission: Bool {
        AgentRowText.permissionButtonsVisible(
            pendingPermissionID: session.pendingPermissionID,
            source: session.source
        )
    }

    @State private var expanded = false
    @State private var detailHeight: CGFloat = 0

    /// Twelve lines of an 11 pt monospaced caption. Past that the block scrolls
    /// instead of pushing the rest of the popover off screen.
    nonisolated static let detailVisibleLines = 12
    nonisolated static let detailLineHeight: CGFloat = 13
    nonisolated static var detailMaxHeight: CGFloat { detailLineHeight * CGFloat(detailVisibleLines) }

    private var showsDetail: Bool {
        AgentRowText.detailIsExpandable(session.activityDetail)
    }

    private var textInset: CGFloat { Self.textInset(showsProviderIcon: showsProviderIcon, metrics: metrics) }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            // The jump target is the row's text, not the whole row: the chevron and
            // the buttons must not be nested inside another button, or which one
            // takes the click stops being predictable.
            HStack(spacing: OMSpacing.xs) {
                Button(action: action) {
                    summaryLine
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(AgentRowText.jumpHelp(for: session))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AgentRowText.accessibilityLabel(for: session))
                .accessibilityHint("Brings the window running this session to the front")
                .accessibilityAddTraits(.isButton)

                if showsDetail { disclosure }
            }

            if expanded, showsDetail, let detail = session.activityDetail {
                detailBlock(detail)
            }

            if showsPermission {
                permissionLine
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The row grows by a line when a request arrives and shrinks when it is
        // answered; without this the list jumps. Reduce Motion gets the jump.
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: showsPermission)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: expanded)
    }

    /// Collapsed by default and per row: an expanded block is a decision about *this*
    /// session, and nothing about it is worth persisting.
    private var disclosure: some View {
        Button {
            expanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.om(.secondary))
                .rotationEffect(.degrees(expanded ? 0 : -90))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(expanded ? "Hide the full text" : "Show the full text")
        .accessibilityLabel(expanded ? "Hide the full text" : "Show the full text")
    }

    /// The whole command, path or plan. Monospaced because most of it is code, and
    /// selectable because the point of showing it is being able to take it.
    private func detailBlock(_ detail: String) -> some View {
        ScrollView(.vertical) {
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.om(.secondary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // Self-sizing, like AgentsSection's list: measure the text, then
                    // take exactly that height up to twelve lines. `.task(id:)` keeps
                    // the write to @State on the main actor under Swift 6.
                    GeometryReader { proxy in
                        Color.clear.task(id: proxy.size.height) { detailHeight = proxy.size.height }
                    }
                }
        }
        .frame(height: min(detailHeight > 0 ? detailHeight : Self.detailMaxHeight, Self.detailMaxHeight))
        .scrollIndicators(detailHeight > Self.detailMaxHeight ? .automatic : .never)
        .scrollDisabled(detailHeight <= Self.detailMaxHeight)
        .padding(.leading, textInset)
    }

    private var summaryLine: some View {
        HStack(spacing: Self.leadingSpacing) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                Text(AgentRowText.rowSubtitle(for: session, providerTab: !showsProviderIcon))
                    .font(.system(size: metrics.subtitleSize))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: OMSpacing.xs)
            // Only the elapsed time is on a clock, so only it re-renders.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AgentRowText.elapsed(since: session.stateSince, now: context.date, state: session.state))
                    .font(.system(size: metrics.subtitleSize))
                    .monospacedDigit()
                    .foregroundStyle(.om(.secondary))
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    /// "test · Needs you": the project, and the badge in the accent when there is one.
    private var titleLine: some View {
        HStack(spacing: 0) {
            Text(session.projectName)
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .truncationMode(.middle)
            if let badge = AgentRowText.titleBadge(session.state) {
                Text(" · \(badge)")
                    .foregroundStyle(.om(.accentText))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: metrics.titleSize, weight: .semibold))
    }

    /// The held request, answerable here. Deliberately plain: the tool it wants to
    /// run is already the subtitle above, and a second copy of it would push the
    /// buttons off a 360 pt popover.
    private var permissionLine: some View {
        HStack(spacing: OMSpacing.s) {
            Button("Allow", action: onAllow)
                .buttonStyle(.omAccent(.small))
                .accessibilityLabel("Allow \(session.projectName) to run this tool")
                .help("Answers Claude Code with allow, once, for this tool call")
            Button("Deny", action: onDeny)
                .buttonStyle(.omCapsule(.small))
                .accessibilityLabel("Deny \(session.projectName) this tool")
                .help("Refuses this one tool call; the session carries on")
            Spacer(minLength: 0)
        }
        .padding(.leading, textInset)
    }

    @ViewBuilder
    private var leading: some View {
        if showsProviderIcon {
            let side = Self.leadingWidth(showsProviderIcon: true, metrics: metrics)
            ProviderIconView(serviceID: session.source.rawValue, sfFallback: Self.sfFallback(session.source), size: metrics.iconSize)
                .foregroundStyle(.om(.secondary))
                .frame(width: side, height: side)
                .overlay(alignment: .bottomTrailing) {
                    // A badge, not a beacon: no halo on a logo; a ring in the window
                    // colour cuts it out of the logo instead.
                    AgentStateDot(state: session.state, diameter: metrics.badgeDiameter, isBadge: true)
                        .offset(x: 3, y: 3)
                }
        } else {
            AgentStateDot(state: session.state, diameter: Self.dotDiameter, isBadge: false)
                .frame(width: Self.leadingWidth(showsProviderIcon: false))
        }
    }

    /// Both sources ship a bundled logo; these only matter to a stripped catalog.
    nonisolated private static func sfFallback(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }
}

/// The state as a colour (`AgentRowText.dotToken`). Standing alone it wears the 3 pt
/// halo a live state has (`haloToken`); as a badge on a logo it wears a ring in the
/// window colour instead. No pulse: the mockups' halo is still, and a halo is not motion.
private struct AgentStateDot: View {
    let state: AgentState
    var diameter: CGFloat = OMAgentRow.dotDiameter
    var isBadge: Bool = false

    var body: some View {
        Circle()
            .fill(.om(AgentRowText.dotToken(state)))
            .frame(width: diameter, height: diameter)
            .background {
                if isBadge {
                    Circle()
                        .fill(.om(.windowBase))
                        .padding(-OMAgentRow.badgeRing)
                } else if let halo = AgentRowText.haloToken(state) {
                    Circle()
                        .fill(.om(halo))
                        .padding(-OMAgentRow.haloWidth)
                }
            }
    }
}

#if DEBUG
/// Fixture sessions for the previews in this file and in `AgentsSection`.
/// DEBUG-only so nothing fake ships in the app binary.
enum AgentPreviewData {
    static func session(
        _ project: String,
        _ state: AgentState,
        activity: String? = nil,
        activityDetail: String? = nil,
        attention: AgentAttention? = nil,
        minutes: Double = 3,
        source: AgentSource = .claude,
        approximate: Bool = false
    ) -> AgentSession {
        let now = Date()
        // `id` is computed by AgentSession from source + sessionID, so the project
        // name doubles as the session id here to keep preview rows distinct.
        return AgentSession(
            sessionID: project,
            source: source,
            projectName: project,
            cwd: "/Users/me/Desktop/\(project)",
            state: state,
            activity: activity,
            activityDetail: activityDetail,
            attention: attention,
            stateSince: now.addingTimeInterval(-minutes * 60),
            lastEventAt: now.addingTimeInterval(-minutes * 60),
            startedAt: now.addingTimeInterval(-3600),
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
            isApproximate: approximate,
            turns: 3,
            needsYouCount: state == .needsYou ? 1 : 0
        )
    }

    /// The mockup's cast: one waiting, two working, one finished.
    static var mixed: [AgentSession] {
        [
            session("Usage tracker", .needsYou, activity: "Regenerate the project", activityDetail: "xcodegen generate", minutes: 1),
            session("Orion Gate / mobile", .working, activity: "Edit WalletView.swift", activityDetail: "/Users/me/Orion/WalletView.swift", minutes: 14),
            session("orion-gemini", .working, activity: "swift test", minutes: 3, source: .codex),
            session("Jaravis", .done, activity: nil, minutes: 5),
        ]
    }
}

/// `View` initialisers are main-actor isolated, so this builder is too — a
/// nonisolated helper would warn on every row it constructs.
@MainActor
private func agentRowPreviewStack(showsProviderIcon: Bool) -> some View {
    VStack(spacing: 5) {
        OMAgentRow(session: AgentPreviewData.session("Usage tracker", .needsYou, activity: "Regenerate the project", activityDetail: "xcodegen generate", minutes: 1), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("Orion Gate / mobile", .working, activity: "Edit WalletView.swift", activityDetail: "/Users/me/Orion/WalletView.swift", minutes: 14), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("Jaravis", .done, minutes: 5), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("orion-gemini", .idle, minutes: 42, source: .codex), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("Movie app", .working, activity: "Grep usageStatusColor", minutes: 2, approximate: true), showsProviderIcon: showsProviderIcon, action: {})
    }
    .padding()
    .frame(width: 328)
}

/// A session with a request in flight, next to one without. `pendingPermissionID`
/// is set after the fact because `AgentSession`'s initializer does not take it —
/// the broker sets it through the store.
@MainActor
private func pendingPermissionPreviewStack(showsProviderIcon: Bool) -> some View {
    var waiting = AgentPreviewData.session(
        "Usage tracker", .needsYou, activity: "Clear the derived data", activityDetail: "rm -rf build/DerivedData", minutes: 1
    )
    waiting.pendingPermissionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    return VStack(spacing: 5) {
        OMAgentRow(session: waiting, showsProviderIcon: showsProviderIcon, onAllow: {}, onDeny: {}, action: {})
        OMAgentRow(
            session: AgentPreviewData.session("Orion Gate / mobile", .working, activity: "Edit WalletView.swift", activityDetail: "/Users/me/Orion/WalletView.swift", minutes: 14),
            showsProviderIcon: showsProviderIcon,
            action: {}
        )
    }
    .padding()
    .frame(width: 328)
}

/// A session waiting on a question: needs-you colours, the question and its options
/// one click away, and no Allow / Deny — the answer is typed in the terminal.
@MainActor
private func attentionPreviewStack() -> some View {
    VStack(spacing: 5) {
        OMAgentRow(
            session: AgentPreviewData.session(
                "Usage tracker", .needsYou,
                activity: "Question: Which provider should the tab default to?",
                activityDetail: "Which provider should the tab default to?\n• Claude Code\n• Codex\n• Grok",
                attention: .question(count: 1, multiSelect: false), minutes: 1
            ),
            action: {}
        )
        OMAgentRow(
            session: AgentPreviewData.session(
                "Orion Gate / mobile", .needsYou,
                activity: "Plan ready for review: Rework the wallet ring",
                activityDetail: "# Rework the wallet ring\n\nStep one.\nStep two.",
                attention: .plan, minutes: 4
            ),
            action: {}
        )
    }
    .padding()
    .frame(width: 328)
}

#Preview("Agent rows — icons, light") { agentRowPreviewStack(showsProviderIcon: true) }
#Preview("Agent rows — icons, dark") { agentRowPreviewStack(showsProviderIcon: true).preferredColorScheme(.dark) }
#Preview("Agent rows — dots, light") { agentRowPreviewStack(showsProviderIcon: false) }
#Preview("Agent rows — dots, dark") { agentRowPreviewStack(showsProviderIcon: false).preferredColorScheme(.dark) }
#Preview("Agent rows — permission pending, light") { pendingPermissionPreviewStack(showsProviderIcon: true) }
#Preview("Agent rows — permission pending, dark") { pendingPermissionPreviewStack(showsProviderIcon: true).preferredColorScheme(.dark) }
#Preview("Agent rows — permission pending, dots") { pendingPermissionPreviewStack(showsProviderIcon: false) }
#Preview("Agent rows — question and plan") { attentionPreviewStack() }
#Preview("Agent rows — question and plan, dark") { attentionPreviewStack().preferredColorScheme(.dark) }
#endif
