import Foundation

/// Every on-disk location the agent overview touches, so the helper, the socket
/// server, the hook installer and the passive scanner can never drift apart.
enum AgentPaths {
    /// ~/Library/Application Support/UsageTracker — the directory `HistoryStore` and
    /// `ModelsDevPricing` already use.
    static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UsageTracker", isDirectory: true)
    }

    /// ~/Library/Application Support/UsageTracker/agent.sock
    static var socketURL: URL { appSupportURL.appendingPathComponent("agent.sock") }

    /// ~/Library/Application Support/UsageTracker/status.json — what the `omelette`
    /// command-line tool reads. `StatusFile` owns the path because the CLI has to
    /// compute it from `$HOME` with no app around to ask; this is the same string,
    /// not a second spelling of it.
    static var statusFileURL: URL { StatusFile.defaultURL() }

    /// ~/Library/Application Support/UsageTracker/bin — the directory hooks, status
    /// lines and the user's own PATH all point at, so that moving or updating the app
    /// breaks nothing.
    static var binURL: URL { appSupportURL.appendingPathComponent("bin", isDirectory: true) }

    /// ~/Library/Application Support/UsageTracker/bin/omelette-hook (symlink → bundle helper).
    static var helperSymlinkURL: URL { binURL.appendingPathComponent(helperName) }

    /// ~/Library/Application Support/UsageTracker/bin/omelette (symlink → bundle CLI).
    static var cliSymlinkURL: URL { binURL.appendingPathComponent(cliName) }

    /// Omelette.app/Contents/Helpers/omelette-hook
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)")
    }

    /// Omelette.app/Contents/Helpers/omelette
    static var bundledCLIURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(cliName)")
    }

    /// ~/Library/Application Support/UsageTracker/agent-sessions.jsonl
    static var historyURL: URL { appSupportURL.appendingPathComponent("agent-sessions.jsonl") }

    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var claudeProjectsURL: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    /// ~/.codex/hooks.json — Codex CLI 0.153.4 reads hooks from here, in Claude's shape.
    static var codexHooksURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var codexSessionsURL: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    /// Bumped together with the helper: 2 = phase 4 (request ids + decisions).
    static let helperVersion = 2
    /// The wire version this app speaks (its reply lines carry it).
    static let wireVersion = 2
    /// Envelope versions the decoder still accepts. A pre-2.2 helper (old symlink
    /// target still running) sends v1 and gets the phase-2 behaviour: no hold.
    static let supportedWireVersions: ClosedRange<Int> = 1...2
    static let helperName = "omelette-hook"
    /// The command the user types. Also the symlink's name and the product name of the
    /// `OmeletteCLI` target — three places that have to agree, one constant.
    static let cliName = "omelette"
    /// Set in the helper's environment to redirect it to another socket (tests use a temp path).
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"
    /// Shortens the helper's decision wait (seconds) — tests only; honoured only
    /// together with a socket override, and never above the production 140 s.
    static let decisionTimeoutEnvironmentKey = "OMELETTE_DECISION_TIMEOUT"
    /// A request id is 128 random bits as lowercase hex.
    static let requestIDLength = 32
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
    static let maxSocketPathBytes = 103

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Points `link` at `target`, creating its directory as needed. Idempotent: a link
    /// that already resolves to `target` is left untouched (returns false). A regular
    /// file, a dangling link or a link to an older copy of the app is replaced
    /// (returns true).
    @discardableResult
    static func refreshSymlink(link: URL, target: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == target.path {
            return false
        }
        // `fileExists` follows symlinks (false for a dangling one); `attributesOfItem`
        // uses lstat, so together they see every kind of leftover.
        if fm.fileExists(atPath: link.path) || (try? fm.attributesOfItem(atPath: link.path)) != nil {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        return true
    }

    /// The hook helper's link. Hook configs reference this path, so moving or updating
    /// the app breaks nothing.
    @discardableResult
    static func refreshHelperSymlink(link: URL = helperSymlinkURL, target: URL = bundledHelperURL) throws -> Bool {
        try refreshSymlink(link: link, target: target)
    }

    /// The CLI's link. Two named entry points because the two links have different
    /// defaults and different failure stories; one implementation because "replace a
    /// link that points somewhere else" has no reason to exist twice.
    @discardableResult
    static func refreshCLISymlink(link: URL = cliSymlinkURL, target: URL = bundledCLIURL) throws -> Bool {
        try refreshSymlink(link: link, target: target)
    }
}
