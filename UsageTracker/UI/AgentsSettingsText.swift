import SwiftUI

/// The Agents tab's words and colours, kept apart from the view that shows them.
/// The view itself reads `~/.claude` and `~/.codex` and a test cannot; these are the
/// parts a test can hold on to.
enum AgentsSettingsText {
    static func hookStatusLabel(_ status: HookInstallStatus) -> String {
        switch status {
        case .installed: return "Installed"
        case .outdated: return "Installed — older than this build"
        case .notInstalled: return "Not installed"
        case .conflict: return "Can't write — something else owns this"
        }
    }

    static func hookStatusTint(_ status: HookInstallStatus) -> Color {
        switch status {
        case .installed: return .green
        case .outdated: return .orange
        case .notInstalled: return .secondary
        case .conflict: return .red
        }
    }

    /// The line under the Codex hooks row. Codex refuses a hook it has not been told
    /// to trust and says nothing when it does, so the tab has to say it instead —
    /// naming the events, because trust is granted per entry and a partial answer is
    /// the confusing case.
    static func codexTrustLine(_ trust: AgentHooksInstaller.CodexTrustStatus) -> (text: String, isTrusted: Bool) {
        switch trust {
        case .trusted:
            return ("Trusted in Codex", true)
        case .awaitingTrust(let events):
            let named = events.isEmpty ? "" : " (\(events.joined(separator: ", ")))"
            return (
                "Run /hooks in Codex once and trust the Omelette hooks\(named) — until then Codex ignores them",
                false
            )
        }
    }

    /// Why Allow / Deny is doing nothing, or nil when at least one agent can hold a
    /// request. Derived from the broker's own truth table, so the caption and the
    /// behaviour cannot disagree.
    static func permissionsInactiveCaption(
        claude: HookInstallStatus,
        codexHooks: HookInstallStatus,
        codexTrust: AgentHooksInstaller.CodexTrustStatus
    ) -> String? {
        let usable = PermissionBroker.featureIsUsable(
            settingEnabled: true, claudeHooks: claude, codexHooks: codexHooks, codexTrust: codexTrust
        )
        guard !usable else { return nil }
        return "Inactive until the Claude Code or Codex hooks above are installed (and, for Codex, trusted)."
    }
}
