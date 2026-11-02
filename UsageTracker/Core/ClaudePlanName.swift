import Foundation

/// The Claude plan's name on the snapshot. Claude Code keeps Anthropic's own name for the plan
/// in `~/.claude.json` ("Ultra" since 2026-10-30), so a rename shows without a release, and
/// `SubscriptionTier`'s mapping is the fallback. The file is about the account Claude Code is
/// signed into, which may not be the one the app polls, and the credential carries no account
/// id; the name follows the rate-limit tier, so the file's name counts only when its tier is
/// the credential's. Team and Enterprise keep the mapping's name: `extraUsageTitle(plan:)`
/// reads "Team" / "Enterprise" off the plan to call their extra usage a spend limit.
enum ClaudePlanName {
    nonisolated static func plan(
        configAccount: ClaudeCodeAccount?,
        subscriptionType: String?,
        rateLimitTier: String?
    ) -> String {
        let tier = SubscriptionTier(rawSubscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
        if !tier.isEnterpriseLike,
           let configAccount,
           let name = configAccount.planDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           let fileTier = comparable(configAccount.organizationRateLimitTier),
           fileTier == comparable(rateLimitTier) {
            return name.lowercased().hasPrefix("claude") ? name : "Claude " + name
        }
        return tier.displayName
    }

    /// A tier as compared: trimmed and lowercased; nil when absent or blank.
    private nonisolated static func comparable(_ tier: String?) -> String? {
        guard let tier = tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !tier.isEmpty else { return nil }
        return tier
    }
}
