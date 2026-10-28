import Foundation

/// What a signed-out Claude can do about it (spec 2026-10-25 § Design › Package 2, Sign in).
enum ClaudeRecovery: Equatable, Sendable {
    /// Sign in: Terminal runs Claude Code's own sign-in.
    case signIn
    /// No Claude Code on this Mac: the install link instead of a button.
    case install
    /// The sign-in is there but needs keychain permission: Settings › Advanced has the button.
    case keychainAccess
    /// The sign-in is there and cannot be read; signing in again would not help.
    case noAction
}

/// What the last Sign in click did, until Claude reads fine again.
enum ClaudeSignInNote: Equatable, Sendable {
    /// Terminal opened; the user is signing in there.
    case pending
    /// It did not start; the words say why.
    case failed(String)
}

/// The popover help behind a signed-out Claude's state: the words, the one way out, and the
/// line under it after a click.
struct ClaudeSignInHelp: Equatable, Sendable {
    let message: String
    let recovery: ClaudeRecovery
    let note: String?
    let noteIsFailure: Bool
}

/// Every word Omelette says about Claude's sign-in (spec 2026-10-25 § Design › Package 2): the
/// snapshot's message per reason, the popover help, the Sign in button, the install link and
/// the lines after a click. Sign-in and renewal are Claude Code's own; nothing here asks for a
/// password or a command to type.
enum ClaudeSignInCopy {
    // MARK: - The snapshot's message, by reason

    static let notFoundMessage = "Not signed in to Claude Code on this Mac."
    static let expiredMessage = "Claude Code's sign-in has expired."
    static let deniedMessage = "Omelette needs your permission to read Claude Code's sign-in."
    // An unreadable sign-in keeps the read's own words ("Keychain read failed (status …)").

    // MARK: - The popover help

    static let signInHelp = "Sign in with Claude Code's own sign-in. It opens in Terminal; Omelette only reads the result."
    static let expiredHelp = "Claude Code's sign-in expired and Claude Code could not renew it on its own. Sign in again; it opens in Terminal."
    static let deniedHelp = "Claude Code's sign-in is in your keychain, but Omelette may not read it yet. Request access in Settings › \(SettingsTab.advanced.rawValue) and click Always Allow."
    static let unreadableHelp = "Claude Code's sign-in is in your keychain but can't be read, so signing in again would not fix it."
    static let installHelp = "Claude Code isn't on this Mac. Install it, or the Claude app, then sign in here."

    // MARK: - The way out

    static let signInButton = "Sign in"
    static let advancedButton = "Open Settings › \(SettingsTab.advanced.rawValue)"
    static let installLinkTitle = "Install Claude Code"
    static let installURL = URL(string: "https://code.claude.com/docs/en/setup")!

    // MARK: - After a click

    static let pendingLine = "Finish signing in in Terminal. Omelette checks again when you come back."
    static let terminalMissing = "Terminal is not on this Mac."
    static let binaryMissing = "Claude Code was not found on this Mac."

    static func launchFailure(_ detail: String) -> String {
        "Sign in did not start: \(detail)"
    }

    static func noteText(_ note: ClaudeSignInNote) -> String {
        switch note {
        case .pending: return pendingLine
        case .failed(let detail): return launchFailure(detail)
        }
    }

    // MARK: - Rules

    /// What a signed-out Claude offers, by why it is signed out. nil for any other provider,
    /// any other state, and Claude switched off. A signed-out Claude without a reason counts
    /// as not signed in.
    static func recovery(for service: ServiceSnapshot?, binaryFound: Bool) -> ClaudeRecovery? {
        guard let service, service.id == ClaudeOAuthProvider.serviceID, service.state == .notSignedIn else {
            return nil
        }
        switch service.signedOutReason ?? .notFound {
        case .notFound, .expired: return binaryFound ? .signIn : .install
        case .denied: return .keychainAccess
        case .unreadable: return .noAction
        }
    }

    /// The popover help for a signed-out Claude. A click's line shows only where a click can
    /// start: beside Sign in, or the install link it fell back to.
    static func help(for service: ServiceSnapshot, binaryFound: Bool, note: ClaudeSignInNote?) -> ClaudeSignInHelp? {
        guard let recovery = recovery(for: service, binaryFound: binaryFound) else { return nil }
        let message: String
        switch recovery {
        case .signIn: message = service.signedOutReason == .expired ? expiredHelp : signInHelp
        case .install: message = installHelp
        case .keychainAccess: message = deniedHelp
        case .noAction: message = unreadableHelp
        }
        let shown = recovery == .signIn || recovery == .install ? note : nil
        var noteIsFailure = false
        if case .failed? = shown { noteIsFailure = true }
        return ClaudeSignInHelp(message: message, recovery: recovery, note: shown.map(noteText), noteIsFailure: noteIsFailure)
    }
}
