import Foundation

/// What the plan's name needs of the account Claude Code is signed into, as `~/.claude.json`
/// keeps it under `oauthAccount`: `"planDisplayName": "Ultra"`,
/// `"organizationRateLimitTier": "default_claude_max_20x"`.
struct ClaudeCodeAccount: Decodable, Equatable, Sendable {
    let planDisplayName: String?
    let organizationRateLimitTier: String?
}

/// Reads `oauthAccount` out of Claude Code's state file. The file is Claude Code's whole state
/// and can run to megabytes, so it is parsed again only when its modification date or size
/// moved, or a link to it points elsewhere; the polls in between are answered from memory. An
/// actor, so the read never runs on the main actor. The provider is built afresh every poll:
/// the memory lives in `shared`.
actor ClaudeCodeAccountReader {
    static let shared = ClaudeCodeAccountReader(fileURL: AgentPaths.claudeConfigURL)

    private struct Stamp: Equatable {
        /// The file behind any link, so a link pointed elsewhere is parsed again.
        let path: String
        let modified: Date
        let size: Int
    }

    private struct StateFile: Decodable {
        let oauthAccount: ClaudeCodeAccount?
    }

    private let fileURL: URL
    /// The file as last parsed and what it held, nil included: a broken file is not parsed
    /// again every poll.
    private var parsed: (stamp: Stamp, account: ClaudeCodeAccount?)?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Claude Code's account; nil when the file is missing or unreadable, is not JSON,
    /// has no `oauthAccount` (signed out), or carries its fields with the wrong types.
    func account() -> ClaudeCodeAccount? {
        // Resolved on every call: a dotfile manager keeps the file as a link, whose own date
        // never moves and whose target can change.
        let file = fileURL.resolvingSymlinksInPath()
        // The stamp is taken before the read: a write in between leaves the memory with newer
        // contents under an older stamp, and the next poll parses again.
        guard let stamp = Self.stamp(of: file) else { return nil }
        if let parsed, parsed.stamp == stamp { return parsed.account }
        let account = (try? Data(contentsOf: file)).flatMap {
            try? JSONDecoder().decode(StateFile.self, from: $0).oauthAccount
        }
        parsed = (stamp, account)
        return account
    }

    /// From `stat`, not `URL.resourceValues`, which caches on the URL this reader keeps.
    private static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        return Stamp(path: url.path, modified: modified, size: size)
    }
}
