import SwiftUI

/// The one-time offer to install Claude Code's hooks, shown above the agents
/// list until it is answered. It says what will be written and where to undo it,
/// because the click writes to a file Omelette does not own — and "Not now" is a
/// real answer: the row never comes back on its own. A group card like the agents
/// below it; Enable is a glass capsule, because Allow is the popover's one filled
/// control.
struct OMHooksPromptRow: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    nonisolated static let title = "See what your agents are doing"
    nonisolated static let caption = """
        Adds hooks to ~/.claude/settings.json so sessions show live status and you \
        get a ping when one needs you. Reversible in Settings → Agents.
        """

    nonisolated static let surface: OMPopoverSurface = .group
    nonisolated static var iconToken: OMColorToken { .working }
    nonisolated static let enableButtonSize: OMButtonSize = .small
    nonisolated static let verticalPadding: CGFloat = 12
    nonisolated static let horizontalPadding: CGFloat = 14

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.om(Self.iconToken))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.om(.text))
                Text(Self.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: OMSpacing.s) {
                    Button("Enable", action: onEnable)
                        .buttonStyle(.omCapsule(Self.enableButtonSize))
                        .help("Writes Omelette's hooks into ~/.claude/settings.json")
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.om(.secondary))
                        .help("Hides this; Settings → Agents can still turn hooks on later")
                }
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverSurface(Self.surface)
    }
}

#if DEBUG
#Preview("Hooks prompt — light") {
    OMHooksPromptRow(onEnable: {}, onDismiss: {})
        .padding().frame(width: 328)
}

#Preview("Hooks prompt — dark") {
    OMHooksPromptRow(onEnable: {}, onDismiss: {})
        .padding().frame(width: 328).preferredColorScheme(.dark)
}

#Preview("Hooks prompt above the agents list") {
    VStack(alignment: .leading, spacing: OMSpacing.s) {
        OMHooksPromptRow(onEnable: {}, onDismiss: {})
        AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
    }
    .padding().frame(width: 328)
}
#endif
