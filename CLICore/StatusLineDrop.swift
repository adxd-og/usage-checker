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

    // MARK: - What the file says

    /// One reading as the file spells it:
    /// `{v, session_id, prompt_id?, total_api_duration_ms?, five_hour?, seven_day?, written_at, config_dir}`.
    /// A key whose value is not known is absent, never `null`. Times are epoch seconds,
    /// as Claude Code writes `resets_at`.
    struct Reading: Codable, Equatable, Sendable {
        /// `v`. A reader skips a file whose version it does not know.
        static let currentFormatVersion = 1

        let formatVersion: Int
        let sessionID: String
        /// With `totalAPIDurationMs`, what tells a reading Claude Code just received from
        /// the same one re-sent on its timer. Absent when the payload had none.
        let promptID: String?
        let totalAPIDurationMs: Double?
        let fiveHour: StatusLineInput.RateLimits.Window?
        let sevenDay: StatusLineInput.RateLimits.Window?
        /// When the CLI wrote the file. Not when Claude Code got the numbers: the
        /// payload does not say.
        let writtenAt: Date
        /// The Claude Code configuration folder the session runs under, so the app can
        /// bind a reading to its account.
        let configDir: String

        enum CodingKeys: String, CodingKey {
            case formatVersion = "v"
            case sessionID = "session_id"
            case promptID = "prompt_id"
            case totalAPIDurationMs = "total_api_duration_ms"
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case writtenAt = "written_at"
            case configDir = "config_dir"
        }
    }

    /// The reading a payload makes, or nil without a session id or a window: nothing
    /// else is worth a file.
    static func reading(from input: StatusLineInput, now: Date, configDir: String) -> Reading? {
        guard let sessionID = input.sessionID,
              let limits = input.rateLimits,
              limits.fiveHour != nil || limits.sevenDay != nil
        else { return nil }
        return Reading(
            formatVersion: Reading.currentFormatVersion,
            sessionID: sessionID,
            promptID: input.promptID,
            totalAPIDurationMs: input.totalAPIDurationMs,
            fiveHour: limits.fiveHour,
            sevenDay: limits.sevenDay,
            writtenAt: now,
            configDir: configDir
        )
    }

    static let configDirEnvironmentKey = "CLAUDE_CONFIG_DIR"

    /// `CLAUDE_CONFIG_DIR` when it is set and not blank, else `~/.claude`: where Claude
    /// Code keeps the session's account. One spelling per folder — no trailing slash,
    /// no `.` or `..` — so the app can compare it with its own; symlinks and `~` are
    /// left as given.
    static func configDir(environment: [String: String], home: URL) -> String {
        if let value = environment[configDirEnvironmentKey],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
        }
        return home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL.path
    }

    /// Computed, as `StatusFile.encoder` is: a shared `JSONEncoder` would be a mutable
    /// global.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    // MARK: - Writing it

    /// What a write came to. The CLI ignores it — every outcome prints the same line —
    /// and the tests read it.
    enum Outcome: Equatable, Sendable {
        case written
        /// No session id, no window, or an id that cannot be a file name.
        case nothingToWrite
        /// The folder could not be made, or the file could not be written or renamed.
        case failed
    }

    /// Writes the payload's reading to `<directory>/<session_id>.json`.
    ///
    /// The folder is made owner-only (0700) on every write, the file 0600; the folder's
    /// parents get the default mode. A folder whose mode cannot be changed is still
    /// written into if it takes the file. The bytes go to a hidden temporary name in the
    /// same folder and are renamed over the old file, so a reader sees the last reading
    /// whole or the new one whole, never half of one. Any failure removes the temporary
    /// file and is `.failed`: never thrown, never printed.
    @discardableResult
    static func write(
        _ input: StatusLineInput,
        to directory: URL,
        now: Date,
        environment: [String: String],
        home: URL
    ) -> Outcome {
        guard let entry = reading(from: input, now: now, configDir: configDir(environment: environment, home: home)),
              let name = fileName(sessionID: entry.sessionID)
        else { return .nothingToWrite }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent(name, isDirectory: false)
        // Dot-prefixed and not `.json`: a reader listing `*.json` never opens it.
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            // An existing folder is tightened too: whoever made it, the reading is the
            // user's alone.
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try encoder.encode(entry)
            try data.write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, target.path) == 0 else {
                try? fileManager.removeItem(at: temporary)
                return .failed
            }
            return .written
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failed
        }
    }
}

/// The drop writes a window in Claude Code's own spelling — `used_percentage`, and
/// `resets_at` in epoch seconds through the drop's encoder — so the file reads like the
/// payload it came from. Here rather than on the type: the parser reads the payload
/// with `JSONSerialization`, and the wire format is this file's business.
extension StatusLineInput.RateLimits.Window: Codable {
    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percentage"
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            usedPercent: try container.decode(Double.self, forKey: .usedPercent),
            resetsAt: try container.decode(Date.self, forKey: .resetsAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
    }
}
