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

    /// ~/Library/Application Support/UsageTracker/bin/omelette-hook (symlink → bundle helper).
    /// Hook configs reference this path, so moving or updating the app breaks nothing.
    static var helperSymlinkURL: URL {
        appSupportURL.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(helperName)
    }

    /// Omelette.app/Contents/Helpers/omelette-hook
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)")
    }

    /// ~/Library/Application Support/UsageTracker/agent-sessions.jsonl
    static var historyURL: URL { appSupportURL.appendingPathComponent("agent-sessions.jsonl") }

    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var claudeProjectsURL: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    static var codexSessionsURL: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    static let helperVersion = 1
    static let wireVersion = 1
    static let helperName = "omelette-hook"
    /// Set in the helper's environment to redirect it to another socket (tests use a temp path).
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
    static let maxSocketPathBytes = 103

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Points `link` at `target`, creating `bin/` as needed. Idempotent: a link that
    /// already resolves to `target` is left untouched (returns false). A regular file,
    /// a dangling link or a link to an older copy of the app is replaced (returns true).
    @discardableResult
    static func refreshHelperSymlink(link: URL = helperSymlinkURL, target: URL = bundledHelperURL) throws -> Bool {
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
}
