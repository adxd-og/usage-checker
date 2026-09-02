import SwiftUI

/// The one-time offer to install Claude Code's hooks, shown above the agents
/// list until it is answered. It says what will be written and where to undo it,
/// because the click writes to a file Omelette does not own — and "Not now" is a
/// real answer: the row never comes back on its own.
struct OMHooksPromptRow: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    nonisolated static let title = "See what your agents are doing"
    nonisolated static let caption = """
        Adds hooks to ~/.claude/settings.json so sessions show live status and you \
        get a ping when one needs you. Reversible in Settings → Agents.
        """

    var body: some View {
        HStack(alignment: .top, spacing: OMSpacing.s + 1) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OMAgentColor.working)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title)
                    .font(OMFont.bodyStrong)
                Text(Self.caption)
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: OMSpacing.s) {
                    Button("Enable", action: onEnable)
                        .glassProminentButtonStyle()
                        .controlSize(.small)
                        .help("Writes Omelette's hooks into ~/.claude/settings.json")
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(OMFont.caption)
                        .foregroundStyle(.secondary)
                        .help("Hides this; Settings → Agents can still turn hooks on later")
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
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
