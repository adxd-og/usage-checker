import Foundation

/// The environment every run of Claude Code from Omelette starts in (spec 2026-10-25 § Design ›
/// Package 2, The environment): without the variables that would point it at another sign-in or
/// make it think it runs inside another session, so it reads and writes the plain
/// `Claude Code-credentials` item.
enum ClaudeCLIEnvironment {
    /// Removed by name; `ANTHROPIC_*` goes by its prefix.
    static let scrubbedKeys = [
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDECODE",
    ]
    static let scrubbedPrefix = "ANTHROPIC_"

    /// What a renewal start adds (spec § The environment): no update, no telemetry, no traffic
    /// Claude Code can do without, and the mark `omelette-hook` reads.
    static let renewalAdditions: [String: String] = [
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_TELEMETRY": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ClaudeRenewalMarker.environmentKey: ClaudeRenewalMarker.value,
    ]

    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !scrubbedKeys.contains(key) && !key.hasPrefix(scrubbedPrefix) }
    }

    /// Omelette's environment minus the scrubbed variables, plus what a renewal needs: HOME and
    /// USER (Claude Code finds its keychain item only with USER set — verification (2),
    /// 2026-10-28), the login shell's PATH first (an npm-installed `claude` needs its `node`),
    /// and a TERM for its full-screen interface. `home` and `user` stand in only where
    /// Omelette's own environment has none.
    static func renewal(base: [String: String], loginPATH: [String]?, home: String, user: String) -> [String: String] {
        var environment = scrubbed(base)
        environment["HOME"] = nonEmpty(base["HOME"]) ?? home
        environment["USER"] = nonEmpty(base["USER"]) ?? user
        environment["PATH"] = path(loginPATH: loginPATH, base: base["PATH"])
        if nonEmpty(environment["TERM"]) == nil { environment["TERM"] = "xterm-256color" }
        environment.merge(renewalAdditions) { _, added in added }
        return environment
    }

    /// The login shell's PATH, then Omelette's own, each folder once; the system's when both
    /// are empty.
    static func path(loginPATH: [String]?, base: String?) -> String {
        var parts = loginPATH ?? []
        parts += (base ?? "").split(separator: ":").map(String.init)
        if parts.isEmpty { parts = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
