import Foundation

/// When Omelette may start Claude Code to renew Claude's sign-in (spec 2026-10-25 § Design ›
/// Package 2, Attempt state is shared). The provider is built anew for every poll, so the state
/// lives here: at most one start every five minutes, counted from the start of an attempt
/// whatever came of it; one at a time; and none while a sign-in launched from the button is
/// under ten minutes old and has not produced a token.
actor ClaudeRenewalGate {
    static let shared = ClaudeRenewalGate()

    nonisolated static let cooldown: TimeInterval = 5 * 60
    nonisolated static let signInWindow: TimeInterval = 10 * 60

    enum Admission: Equatable, Sendable {
        case run
        case coolingDown
        case signInPending
    }

    enum Outcome: Equatable, Sendable {
        /// Claude Code wrote a newer token.
        case renewed(ClaudeCredentials.OAuth)
        /// It started and nothing newer came of it.
        case failed
        /// It was not started.
        case refused(Admission)
    }

    private var lastAttemptAt: Date?
    private var signInLaunchedAt: Date?
    /// An attempt is running: the next caller is refused whatever the clock says.
    private var inFlight = false

    /// The rule, on its own. A pending sign-in says more than a cooldown.
    nonisolated static func admission(now: Date, lastAttemptAt: Date?, signInLaunchedAt: Date?) -> Admission {
        if let signInLaunchedAt, now.timeIntervalSince(signInLaunchedAt) < signInWindow { return .signInPending }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < cooldown { return .coolingDown }
        return .run
    }

    /// What an attempt now would be told: the provider asks first, so a refused attempt reads
    /// nothing from the keychain.
    func admission(now: Date) -> Admission {
        if inFlight { return .coolingDown }
        return Self.admission(now: now, lastAttemptAt: lastAttemptAt, signInLaunchedAt: signInLaunchedAt)
    }

    /// Runs `body` — one start of Claude Code and the read after it — when the rule allows. The
    /// attempt is counted before `body` runs, so a second caller meanwhile is refused: never two
    /// starts at once.
    func attempt(now: Date, _ body: @escaping @Sendable () async -> ClaudeCredentials.OAuth?) async -> Outcome {
        let verdict = self.admission(now: now)
        guard verdict == .run else { return .refused(verdict) }
        lastAttemptAt = now
        // The actor lets other callers in while `body` awaits: the flag, not the clock, keeps
        // them out until this attempt is over.
        inFlight = true
        defer { inFlight = false }
        guard let renewed = await body() else { return .failed }
        return .renewed(renewed)
    }

    /// The Sign in button is opening Terminal (held from the click, before Terminal opens).
    func signInLaunched(at date: Date) {
        signInLaunchedAt = date
    }

    /// Terminal did not open: no sign-in is pending after all.
    func signInDidNotOpen() {
        signInLaunchedAt = nil
    }

    /// Claude read fine: whatever sign-in was pending is over.
    func tokenArrived() {
        signInLaunchedAt = nil
    }

    /// Whether a sign-in from the button is still pending: what an app activation asks.
    func isSignInPending(now: Date) -> Bool {
        Self.admission(now: now, lastAttemptAt: nil, signInLaunchedAt: signInLaunchedAt) == .signInPending
    }
}

/// What the provider needs to have Claude Code renew a sign-in: the shared gate, the binary
/// rule and one start. Values, so a test hands in its own.
struct ClaudeRenewal: Sendable {
    var gate: ClaudeRenewalGate
    var locateBinary: @Sendable () -> String?
    var start: @Sendable (_ binary: String) async -> Void

    static let live = ClaudeRenewal(
        gate: .shared,
        locateBinary: { ClaudeBinaryLocator.locate() },
        start: { await ClaudeRenewalProbe.startForRenewal(binary: $0) }
    )
}
