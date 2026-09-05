import Foundation

enum AgentSource: String, Codable, Sendable {
    case claude, codex
}

enum AgentState: String, Codable, Sendable, CaseIterable {
    case needsYou, working, done, idle

    /// Sort/grouping order: needsYou < working < done < idle
    var rank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }
}

/// The terminal / IDE process a session runs under, as reported by the helper.
struct AgentHostInfo: Codable, Equatable, Sendable {
    var pid: Int32?
    var bundleID: String?
    var tty: String?

    static let none = AgentHostInfo(pid: nil, bundleID: nil, tty: nil)

    /// Wire spelling (`host` object of the helper envelope).
    enum CodingKeys: String, CodingKey {
        case pid
        case bundleID = "bundle_id"
        case tty
    }
}

/// What the app reacts to. Decoded from the wire message; `kind` is derived from
/// `payload.hook_event_name` (+ `notification_type`) for Claude and from `payload.type`
/// for Codex.
struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStart, promptSubmitted, toolStarted, toolFinished
        case permissionRequested, notificationPermission, notificationIdle
        case stop, sessionEnd
        case codexTurnComplete
        case unknown(String)
    }

    let source: AgentSource
    let kind: Kind
    let sessionID: String            // Claude session_id / Codex thread-id
    let cwd: String?
    let toolName: String?
    let toolSummary: String?         // ToolSummary.headline
    /// The full text behind the headline (`ToolSummary.detail`): the command, the
    /// path, the plan. nil when the headline says it all.
    let toolDetail: String?
    /// Set when the tool call *is* the thing the user has to answer — a question or
    /// a plan. Neither can be answered from Omelette.
    let attention: AgentAttention?
    let isSubagent: Bool             // payload has agent_id
    let host: AgentHostInfo
    let receivedAt: Date
    /// Wire v2: the helper's one-shot id for a `PermissionRequest` it is waiting on.
    /// nil for every other event and for a v1 helper.
    let requestID: String?

    init(
        source: AgentSource,
        kind: Kind,
        sessionID: String,
        cwd: String?,
        toolName: String?,
        toolSummary: String?,
        toolDetail: String? = nil,
        attention: AgentAttention? = nil,
        isSubagent: Bool,
        host: AgentHostInfo,
        receivedAt: Date,
        requestID: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.toolDetail = toolDetail
        self.attention = attention
        self.isSubagent = isSubagent
        self.host = host
        self.receivedAt = receivedAt
        self.requestID = requestID
    }
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String                   // "\(source.rawValue):\(sessionID)"
    let sessionID: String
    let source: AgentSource
    var projectName: String          // ProjectName(...) of cwd, or last path component (package 2 fills it)
    var cwd: String?
    var state: AgentState
    var activity: String?            // last tool summary headline
    /// The full text behind `activity`, for the row's expanded block. Moves with
    /// `activity` as a pair — a headline from one tool over the detail of another
    /// would expand into a lie.
    var activityDetail: String?
    /// The session is waiting on a question or a plan, which is a `needsYou` with no
    /// Allow / Deny: the answer has to be typed in the terminal.
    var attention: AgentAttention?
    var stateSince: Date
    var lastEventAt: Date
    var startedAt: Date
    var host: AgentHostInfo
    var isApproximate: Bool          // true for passive-scan sessions
    var turns: Int
    var needsYouCount: Int
    /// The `request_id` of a permission request Omelette is holding for this session
    /// (Allow / Deny buttons in the popover). Owned by `PermissionBroker`, written only
    /// through `AgentSessionStore.setPendingPermission(id:for:)`.
    var pendingPermissionID: String?

    static func makeID(source: AgentSource, sessionID: String) -> String {
        "\(source.rawValue):\(sessionID)"
    }

    init(
        sessionID: String,
        source: AgentSource,
        projectName: String,
        cwd: String?,
        state: AgentState,
        activity: String? = nil,
        activityDetail: String? = nil,
        attention: AgentAttention? = nil,
        stateSince: Date,
        lastEventAt: Date,
        startedAt: Date,
        host: AgentHostInfo = .none,
        isApproximate: Bool = false,
        turns: Int = 0,
        needsYouCount: Int = 0,
        pendingPermissionID: String? = nil
    ) {
        self.id = Self.makeID(source: source, sessionID: sessionID)
        self.sessionID = sessionID
        self.source = source
        self.projectName = projectName
        self.cwd = cwd
        self.state = state
        self.activity = activity
        self.activityDetail = activityDetail
        self.attention = attention
        self.stateSince = stateSince
        self.lastEventAt = lastEventAt
        self.startedAt = startedAt
        self.host = host
        self.isApproximate = isApproximate
        self.turns = turns
        self.needsYouCount = needsYouCount
        self.pendingPermissionID = pendingPermissionID
    }
}
