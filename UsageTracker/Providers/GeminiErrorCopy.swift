import CodexBarCore
import Foundation

/// Gemini's failures, said in Omelette's words.
///
/// Google shut consumer-tier Gemini CLI OAuth down in June 2026, and CodexBarCore's
/// message for it tells the user to "Enable CodexBar's Antigravity provider" — advice
/// about an app they are not running, pointing at a settings screen that does not
/// exist here. Omelette has its own Antigravity provider and its own Settings, so it
/// says so itself. The state stays `.notSignedIn`: signing in again is still the first
/// thing to try, and Antigravity is the way through when it doesn't work.
enum GeminiErrorCopy {
    static let antigravityAdvice = "Sign in to the Gemini CLI again, or enable Antigravity in Settings → Providers."

    /// Two ways in, because upstream is a 0.x pin. The enum case is matched directly;
    /// anything else whose message points at CodexBar's Antigravity provider is caught
    /// by its text, which covers a renamed or newly added case (the upstream bump adds
    /// one for unavailable OAuth credentials) without this file having to name it.
    static func stateMessage(for error: Error) -> String {
        if let probe = error as? GeminiStatusProbeError, probe == .consumerTierDeprecated {
            return antigravityAdvice
        }
        let described = error.localizedDescription
        if described.localizedCaseInsensitiveContains("Antigravity provider") {
            return antigravityAdvice
        }
        return described
    }
}
