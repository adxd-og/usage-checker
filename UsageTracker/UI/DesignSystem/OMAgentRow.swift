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
/// dot alone on a provider tab, where the provider is already the tab. The whole
/// row is a button: clicking it jumps to that session.
struct OMAgentRow: View {
    let session: AgentSession
    var showsProviderIcon: Bool = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
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
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Jump to \(session.projectName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentRowText.accessibilityLabel(for: session))
        .accessibilityHint("Brings the window running this session to the front")
        .accessibilityAddTraits(.isButton)
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
            session("Usage tracker", .needsYou, activity: "Bash: xcodegen generate", minutes: 1),
            session("Orion Gate / mobile", .working, activity: "Edit: WalletView.swift", minutes: 14),
            session("orion-gemini", .working, activity: "Bash: swift test", minutes: 3, source: .codex),
            session("Jaravis", .done, activity: nil, minutes: 5),
        ]
    }
}

/// `View` initialisers are main-actor isolated, so this builder is too — a
/// nonisolated helper would warn on every row it constructs.
@MainActor
private func agentRowPreviewStack(showsProviderIcon: Bool) -> some View {
    VStack(spacing: 5) {
        OMAgentRow(session: AgentPreviewData.session("Usage tracker", .needsYou, activity: "Bash: xcodegen generate", minutes: 1), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("Orion Gate / mobile", .working, activity: "Edit: WalletView.swift", minutes: 14), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("Jaravis", .done, minutes: 5), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("orion-gemini", .idle, minutes: 42, source: .codex), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("Movie app", .working, activity: "Grep: usageStatusColor", minutes: 2, approximate: true), showsProviderIcon: showsProviderIcon) {}
    }
    .padding()
    .frame(width: 328)
}

#Preview("Agent rows — icons, light") { agentRowPreviewStack(showsProviderIcon: true) }
#Preview("Agent rows — icons, dark") { agentRowPreviewStack(showsProviderIcon: true).preferredColorScheme(.dark) }
#Preview("Agent rows — dots, light") { agentRowPreviewStack(showsProviderIcon: false) }
#Preview("Agent rows — dots, dark") { agentRowPreviewStack(showsProviderIcon: false).preferredColorScheme(.dark) }
#endif
