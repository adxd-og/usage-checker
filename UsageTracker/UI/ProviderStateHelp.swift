import Foundation

/// The way out behind a provider's state on its page (notch-island spec 2026-10-29 § 3.3,
/// decisions moved out of views): the words, a command to copy, the app to open, a link,
/// and Claude's own sign-in help. Pure: whether Antigravity is installed is read once per
/// open, off the main thread, with the hook status, and handed in.
struct ProviderStateHelp: Equatable, Sendable {
    let message: String
    var command: String? = nil
    var appPath: String? = nil
    var linkTitle: String? = nil
    var linkURL: URL? = nil
    /// Claude's way out when it is signed out (spec 2026-10-25 § Package 2).
    var claude: ClaudeSignInHelp? = nil

    static let antigravityAppPath = "/Applications/Antigravity.app"
    static let codexMessage = "Codex reports limits only for ChatGPT sign-in (API-key auth doesn't expose them)."
    static let codexCommand = "codex logout && codex login"
    static let antigravityMessage = "Antigravity shares quotas only while the app, `agy` CLI, or IDE is running."
    static let antigravityCommand = "agy"
    static let grokMessage = "Sign into the Grok CLI, then refresh. Credits reset with your xAI billing period."
    static let grokCommand = "grok login"
    static let grokLinkTitle = "Open grok.com usage"
    static let grokLinkURL = URL(string: "https://grok.com/?_s=usage")!
    /// The help's buttons: copy the command, open the installed app.
    static let copyButton = "Copy"
    static let openAntigravityButton = "Open Antigravity"

    /// nil when the state has no way out to offer.
    static func help(
        for service: ServiceSnapshot,
        claudeBinaryFound: Bool,
        claudeNote: ClaudeSignInNote?,
        antigravityInstalled: Bool
    ) -> ProviderStateHelp? {
        switch (service.id, service.state) {
        case ("claude", .notSignedIn):
            // Why Claude is signed out decides the way out (spec 2026-10-25 § Package 2).
            guard let help = ClaudeSignInCopy.help(for: service, binaryFound: claudeBinaryFound, note: claudeNote)
            else { return nil }
            return ProviderStateHelp(message: help.message, claude: help)
        case ("codex", .notSignedIn):
            return ProviderStateHelp(message: codexMessage, command: codexCommand)
        case ("antigravity", _) where service.state != .ok:
            return ProviderStateHelp(
                message: antigravityMessage,
                command: antigravityInstalled ? nil : antigravityCommand,
                appPath: antigravityInstalled ? antigravityAppPath : nil
            )
        case ("grok", .notSignedIn):
            return ProviderStateHelp(
                message: grokMessage, command: grokCommand, linkTitle: grokLinkTitle, linkURL: grokLinkURL
            )
        case ("mistral", .notSignedIn):
            // No key anywhere, or a key Mistral refused (spec 2026-11-10 § States).
            return ProviderStateHelp(
                message: service.signedOutReason == .expired ? MistralCopy.signedOutHelp : MistralCopy.notSignedInHelp,
                command: MistralCopy.command
            )
        case ("mistral", .error) where service.stateMessage == MistralCopy.noUsageAccessMessage:
            return ProviderStateHelp(message: MistralCopy.noUsageAccessHelp)
        default:
            return nil
        }
    }
}
