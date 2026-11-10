import Foundation

/// Every word Brioche says about Mistral (spec 2026-11-10 Mistral provider): its name, the
/// windows' labels and the plan chip; the states' messages and the help behind them follow.
enum MistralCopy {
    static let displayName = "Mistral"
    static let vibeLabel = "Vibe"
    static let apiLabel = "API"

    // MARK: - The states' messages (spec § States)

    /// No key in vibe's keychain item or `~/.vibe/.env`; an OIDC-only sign-in too.
    static let notSignedInMessage = "Not signed in: no Mistral API key in vibe's keychain item or ~/.vibe/.env."
    /// Billing answered 401.
    static let signedOutMessage = "Signed out: Mistral did not accept the API key vibe keeps."
    /// `/budget` answered 403: the plan is known, the usage is not.
    static let noUsageAccessMessage = "No usage access: this API key may not see its organisation's usage."
    /// `/budget` answered 429.
    static let rateLimitedMessage = "Rate limited by Mistral's billing API"

    /// The plan chip from billing's `plan_name`: vibe's names for the chat plans
    /// (`vibe/setup/auth/whoami.py`), which billing shares; an unknown name capitalised; nil
    /// when billing said nothing.
    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "FREE": return "Free"
        case "INDIVIDUAL": return "Pro"
        case "EDU": return "Student"
        case "TEAM": return "Team"
        default: return raw.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
        }
    }
}
