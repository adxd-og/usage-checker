import Foundation

/// The status line's reading drop: Claude's rate limits, as Claude Code piped them
/// into `brioche statusline`, left in a file for the app (spec 2026-11-02 Claude limits
/// from the status line, § Design › Wire).
///
/// A file, not the socket: it works while the app is closed — the next launch picks it
/// up — and with a Debug and a Release copy running at once. One file per session,
/// named by its id, in a folder only the user can open, beside `status.json`.
///
/// The CLI's one write (see the contract in `CLI/main.swift`). Every way it can fail is
/// silent: the status line has already printed and has nowhere to say so.
enum StatusLineDrop {
    /// Redirects the drop to another folder, as `OMELETTE_STATUS_FILE` redirects the
    /// status file: the end-to-end tests point it at a temp path, so no test ever
    /// writes into the real Application Support. It needs no Debug-only allowlist for
    /// the same reason: anything that can set this variable can already write any file
    /// as you.
    static let environmentKey = "OMELETTE_STATUSLINE_DIR"

    static let directoryName = "statusline"

    /// `~/Library/Application Support/UsageTracker/statusline`, beside `status.json`,
    /// derived from `StatusFile.defaultURL` so the two cannot drift apart.
    static func defaultDirectoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        StatusFile.defaultURL(home: home)
            .deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func directoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultDirectoryURL(home: home)
    }

    /// What a session id may hold to become a file name: ASCII letters, digits and the
    /// hyphen of a UUID. Nothing that climbs out of the folder (`/`, `..`), hides a file
    /// (`.`), or spells the same name two ways (anything beyond ASCII).
    private static let fileNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
    )

    /// `<session_id>.json`, or nil when the id holds anything else. Checked, never
    /// cleaned: stripping would give two sessions one file.
    static func fileName(sessionID: String) -> String? {
        guard !sessionID.isEmpty,
              sessionID.unicodeScalars.allSatisfy({ fileNameCharacters.contains($0) })
        else { return nil }
        return sessionID + ".json"
    }
}
