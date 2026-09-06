import Foundation

/// What Omelette knows, as the `omelette` command-line tool reads it.
///
/// Written by the app to `~/Library/Application Support/UsageTracker/status.json`
/// after every poll (`StatusFileWriter`), read by the CLI and by nothing else.
///
/// Deliberately *not* the widget's snapshot. `widget-snapshot-v2.json` lives in the
/// App Group container, is decoded by a separate process that updates on its own
/// schedule, and carries no costs and no agents; a key added to it has to decode as
/// absent on every desktop widget already installed. This file is a superset of it in
/// content and a stranger to it in format — the two are written side by side from the
/// same poll and neither is derived from the other. `SharedWidgetData.swift` is not
/// touched by this package.
///
/// Compiled into both the app and the CLI target (`CLICore/` appears in both `sources`
/// lists), so the writer and the reader can never disagree about a key.
struct StatusSnapshot: Codable, Equatable, Sendable {
    /// Bumped when a key changes meaning. The CLI refuses a file it does not know
    /// rather than half-reading it.
    static let currentVersion = 1

    /// Older than this and the CLI says Omelette is not running. The poll runs every
    /// 60 s by default and the slowest setting is 5 minutes, so ten minutes of silence
    /// means the app is gone, asleep or locked — in every case the numbers are a guess,
    /// and a status line that guesses is worse than one that is blank.
    static let freshness: TimeInterval = 600

    var version: Int
    var updatedAt: Date
    var services: [Service]
    var agents: Agents

    /// One provider, in the words the app already uses for it.
    struct Service: Codable, Equatable, Sendable {
        let id: String
        let name: String
        /// `ServiceState.rawValue`: "ok", "notSignedIn", "notRunning", "error".
        let state: String
        /// The provider stopped reporting and these are its last known numbers.
        let retained: Bool
        /// When those retained numbers were last true. nil for a live service.
        var retainedAt: Date?
        var plan: String?
        var windows: [Window]
        /// Only for providers that write a local per-turn cost log (Claude Code, the
        /// Codex CLI, the Grok CLI). Absent for the others rather than zero — "no log"
        /// and "spent nothing today" are different answers.
        var todayCost: Double?
        var weekCost: Double?
        var todayTokens: Int?
        /// These dollars are an API-list-price equivalent of local CLI usage, not what
        /// a subscription bills. False for a pay-as-you-go account, where the figure is
        /// close to the real bill. Absent when there are no dollars to qualify.
        var apiEquivalent: Bool?
    }

    /// One rate-limit window of a service.
    struct Window: Codable, Equatable, Sendable {
        let id: String
        let label: String
        /// 0…100, and above 100 when a spend limit is over. Unclamped on purpose: the
        /// renderers decide how to show "past the limit", the file records what is true.
        let percent: Double
        /// nil when the provider reports no reset time, or reports one at the end of
        /// time (`Date.distantFuture`, which is how the app spells "unknown").
        var resetsAt: Date?
        /// `BucketKind.rawValue`: "session", "weekly", "modelSpecific", "other".
        var kind: String?

        /// Bonus quota pools. Running one dry costs nothing, so they never lead a
        /// headline — the same rule as `UsageBucket.isPromotional`.
        var isPromotional: Bool {
            id.lowercased().contains("promo") || label.lowercased().contains("promo")
        }
    }

    /// The agent sessions Omelette can see, and the two counts the CLI shows.
    struct Agents: Codable, Equatable, Sendable {
        var needsYou: Int
        var working: Int
        var sessions: [Session]

        static let none = Agents(needsYou: 0, working: 0, sessions: [])
    }

    struct Session: Codable, Equatable, Sendable {
        let id: String
        let project: String
        /// `AgentState.rawValue`: "needsYou", "working", "done", "idle".
        let state: String
        var activity: String?
    }

    /// Whether these numbers are recent enough to speak for. See `freshness`.
    func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) < Self.freshness
    }

    func service(id: String) -> Service? {
        services.first { $0.id == id }
    }
}

/// The file itself: where it lives, and how to read and write it. One encoder for
/// both sides, so the bytes the app writes are the bytes the CLI expects.
enum StatusFile {
    static let name = "status.json"

    /// Redirects the tool to another file — the end-to-end tests point it at a temp
    /// path. Unlike the helper's socket override this needs no Debug-only allowlist:
    /// the file is read-only, holds no secret and decides nothing, and anything that
    /// can set an environment variable on your shell can already run any command as you.
    static let environmentKey = "OMELETTE_STATUS_FILE"

    /// `~/Library/Application Support/UsageTracker/status.json`, computed from `$HOME`
    /// because the CLI has no app around to ask. `AgentPaths.statusFileURL` returns
    /// this same value, so the two spellings cannot drift.
    static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/UsageTracker", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return defaultURL(home: home)
    }

    /// Computed rather than stored: `JSONEncoder` is a class, and a shared instance
    /// would be a mutable global that two actors could reach at once.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The decoded snapshot, or nil when the file is missing, unreadable, not JSON, or
    /// written by a version this build does not know. Every failure is the same answer
    /// to the user — "Omelette is not running" — so none of them is worth an error type.
    static func load(from url: URL) -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(StatusSnapshot.self, from: data),
              snapshot.version == StatusSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// The raw bytes, for `omelette status --json`, which prints the file verbatim
    /// rather than re-encoding it.
    static func read(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
