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
    static func jumpHelp(for session: AgentSession) -> String {
        session.attention == nil
            ? "Jump to \(session.projectName)"
            : "Click to go to the terminal and answer"
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

    private static func isFinished(_ state: AgentState) -> Bool {
        state == .done || state == .idle
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

/// One agent session. The leading element is the provider logo with a small
/// state badge on the All tab, where rows from every provider mix, and the state
/// dot alone on a provider tab, where the provider is already the tab. The row's
/// summary line is a button: clicking it jumps to that session. A session with a
/// held permission request grows a second line carrying **Allow** / **Deny**,
/// which is why the button is the line and not the whole card.
struct OMAgentRow: View {
    let session: AgentSession
    var showsProviderIcon: Bool = true
    /// Called by the row's **Allow** / **Deny**. Defaults do nothing so previews and
    /// any host that does not deal in permissions can ignore them. They precede
    /// `action`, which is why every call site passes `action:` by name: an unlabeled
    /// trailing closure would be matched against `onAllow` first.
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs + 2) {
            // The jump target is the row's text, not the whole card: the chevron and
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
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
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
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
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
        .padding(.leading, 20 + OMSpacing.s + 1)   // clears the leading icon, so the text lines up
    }

    private var summaryLine: some View {
        HStack(spacing: OMSpacing.s + 1) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AgentRowText.subtitle(for: session, showsState: !showsProviderIcon))
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: OMSpacing.xs)
            // Only the elapsed time is on a clock, so only it re-renders.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AgentRowText.elapsed(since: session.stateSince, now: context.date, state: session.state))
                    .font(OMFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    /// The held request, answerable here. Deliberately plain: the tool it wants to
    /// run is already the subtitle above, and a second copy of it would push the
    /// buttons off a 360 pt popover.
    private var permissionLine: some View {
        HStack(spacing: OMSpacing.s) {
            Button("Allow", action: onAllow)
                .glassProminentButtonStyle()
                .controlSize(.small)
                .accessibilityLabel("Allow \(session.projectName) to run this tool")
                .help("Answers Claude Code with allow, once, for this tool call")
            Button("Deny", action: onDeny)
                .glassButtonStyle()
                .controlSize(.small)
                .accessibilityLabel("Deny \(session.projectName) this tool")
                .help("Refuses this one tool call; the session carries on")
            Spacer(minLength: 0)
        }
        .padding(.leading, 20 + OMSpacing.s + 1)   // clears the leading icon, so the buttons line up under the text
    }

    @ViewBuilder
    private var leading: some View {
        if showsProviderIcon {
            ProviderIconView(serviceID: session.source.rawValue, sfFallback: Self.sfFallback(session.source), size: 18)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .overlay(alignment: .bottomTrailing) {
                    // A badge, not a beacon: the group heading already says the
                    // state on this tab, so the dot never pulses here.
                    AgentStateDot(state: session.state, animates: false, diameter: 6)
                        .padding(1)
                        .background(Circle().fill(.background))
                        .offset(x: 3, y: 3)
                }
        } else {
            AgentStateDot(state: session.state, animates: !reduceMotion, diameter: 8)
                .frame(width: 20, height: 20)
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

/// The state as a colour: amber with a halo when the agent is waiting for you,
/// a pulsing blue while it works, green when the turn is done, grey when idle.
/// Reduce Motion drops the pulse; the halo stays, because a halo is not motion.
private struct AgentStateDot: View {
    let state: AgentState
    var animates: Bool = true
    var diameter: CGFloat = 8

    @State private var pulsing = false

    private var color: Color {
        switch state {
        case .needsYou: return OMAgentColor.needsYou
        case .working: return OMAgentColor.working
        case .done: return OMAgentColor.done
        case .idle: return OMAgentColor.idle
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                if state == .needsYou {
                    Circle()
                        .strokeBorder(color.opacity(0.28), lineWidth: 3)
                        .padding(-3)
                }
            }
            .background {
                if state == .working, animates {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 2)
                        .scaleEffect(pulsing ? 2.2 : 1)
                        .opacity(pulsing ? 0 : 0.6)
                }
            }
            .onAppear {
                guard state == .working, animates else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulsing = true
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
