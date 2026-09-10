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
    /// rather than half-reading it. 2 added `Service.sessions` — an `omelette` from
    /// 2.4.1 has no idea what a chat is, and a list it cannot show is better refused
    /// than silently dropped.
    static let currentVersion = 2

    /// Older than this and the CLI says Omelette is not running. The poll runs every
    /// 60 s by default and the slowest setting is 5 minutes, so ten minutes of silence
    /// means the app is gone, asleep or locked — in every case the numbers are a guess,
    /// and a status line that guesses is worse than one that is blank.
    static let freshness: TimeInterval = 600

    var version: Int
    var updatedAt: Date
    var services: [Service]
    var agents: Agents
    /// The app's "show remaining instead of used" switch. The numbers above stay
    /// "used": this file is a machine contract, `omelette status --json` prints it
    /// verbatim, and inverting them would break every script that reads it. Only the
    /// human-readable lines `StatusText` and `StatusLineText` render follow this.
    ///
    /// Defaulted, and decoded as optional (see the extension below), so a file
    /// written before 2.5 still opens: it is the same v2 shape with one key missing,
    /// not a different version, and bumping the version would make every already
    /// installed `omelette` refuse a file it can read perfectly.
    var showsRemaining: Bool = false

    /// Spelled out because the decoder below needs them, and so a renamed property
    /// cannot silently orphan a key that is already on disk.
    enum CodingKeys: String, CodingKey {
        case version, updatedAt, services, agents, showsRemaining
    }

    /// The mode the two renderers read.
    var percentMode: PercentDisplay.Mode { showsRemaining ? .remaining : .used }

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
        /// The chats this provider's own session log knows about — the last seven days,
        /// ranked by `SessionListRule.pick` and capped at `StatusFileWriter.maxFileSessions`.
        /// Absent, not empty, for a provider whose log names no chat (Grok, Gemini,
        /// Antigravity) and for a quiet week: "no chat log" and "no chats" are different
        /// answers, and the optional is also what lets the synthesized decoder accept a
        /// `Service` object written without the key.
        var sessions: [SessionEntry]?
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

    /// One chat, as the file records it.
    ///
    /// `title` is a plain `String` and never nil: the app resolves the "<project> ·
    /// <first day>" fallback through `SessionCopy.rowTitle` before writing. The CLI
    /// target cannot see `SessionSummary` or `ProjectName`, and a second copy of that
    /// fallback here would be a user-visible string decided outside a tested rule.
    struct SessionEntry: Codable, Equatable, Sendable {
        /// Provider-local session id.
        let id: String
        let title: String
        /// The project's display name, already decoded from the provider's own slug.
        let project: String
        let lastAt: Date
        let turns: Int
        /// `TokenBreakdown.total`: the five disjoint buckets, thinking excluded.
        let tokens: Int
        /// nil for a provider that prices a turn as a whole and left no split.
        var cost: Double?
        /// How many sub-agents the chat launched.
        let agents: Int
        /// Codex `originator` (`codex-tui`, `codex_exec`, …); nil for Claude.
        var origin: String?
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

/// Reading a file an older build wrote. A property default is not a *decoding*
/// default — the synthesized `init(from:)` would throw `keyNotFound` on a 2.4.1
/// file — and the CLI answers any decode failure with "Omelette is not running",
/// which would be a lie. In an extension so the memberwise initializer every call
/// site and every test uses survives.
extension StatusSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        self.agents = try c.decodeIfPresent(Agents.self, forKey: .agents) ?? .none
        self.showsRemaining = try c.decodeIfPresent(Bool.self, forKey: .showsRemaining) ?? false
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
