import Foundation
@testable import Omelette

/// The exact JSON the agents hand the helper, and the envelope the helper wraps it in.
enum AgentFixture {
    static let hostJSON = #"{"pid":4242,"bundle_id":"com.googlecode.iterm2","tty":"/dev/ttys004"}"#

    /// One Claude Code hook payload. `extra` is appended verbatim inside the object
    /// (leading comma included by this function).
    static func claude(
        _ event: String,
        sessionID: String = "sess-1",
        cwd: String = "/Users/me/Desktop/Usage tracker",
        extra: String = ""
    ) -> String {
        let tail = extra.isEmpty ? "" : "," + extra
        return #"{"session_id":"\#(sessionID)","transcript_path":"/Users/me/.claude/projects/-Users-me-Desktop-Usage-tracker/\#(sessionID).jsonl","cwd":"\#(cwd)","permission_mode":"default","hook_event_name":"\#(event)"\#(tail)}"#
    }

    static let sessionStart = claude("SessionStart", extra: #""source":"startup""#)
    static let userPromptSubmit = claude("UserPromptSubmit", extra: #""prompt":"fix the ring""#)
    static let preToolUseBash = claude("PreToolUse", extra: #""tool_name":"Bash","tool_input":{"command":"xcodegen generate","description":"Regenerate the project"},"tool_use_id":"toolu_01""#)
    static let postToolUseBash = claude("PostToolUse", extra: #""tool_name":"Bash","tool_input":{"command":"xcodegen generate"},"tool_response":{"stdout":"ok","stderr":"","interrupted":false},"tool_use_id":"toolu_01""#)
    static let permissionRequestEdit = claude("PermissionRequest", extra: #""tool_name":"Edit","tool_input":{"file_path":"/Users/me/Desktop/Usage tracker/UsageTracker/UI/WalletView.swift","old_string":"a","new_string":"b"},"tool_use_id":"toolu_02""#)
    static let notificationPermission = claude("Notification", extra: #""message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
    static let notificationIdle = claude("Notification", extra: #""message":"Claude is waiting for your input","notification_type":"idle_prompt""#)
    static let notificationOther = claude("Notification", extra: #""message":"Auth expired","notification_type":"auth_success""#)
    static let stop = claude("Stop", extra: #""stop_hook_active":false"#)
    static let sessionEnd = claude("SessionEnd", extra: #""reason":"exit""#)
    static let subagentPreToolUse = claude("PreToolUse", extra: #""agent_id":"agent-7","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"AgentEvent"}"#)
    static let unknownEvent = claude("SubagentStop", extra: #""agent_id":"agent-7""#)

    /// Codex `notify` argument: kebab-case keys, only `agent-turn-complete` exists today.
    static let codexTurnComplete = #"{"type":"agent-turn-complete","thread-id":"thr-9","turn-id":"turn-2","cwd":"/Users/me/Desktop/Orion Gate","input-messages":["ship it"],"last-assistant-message":"Done."}"#

    static func envelope(
        source: String = "claude",
        payload: String,
        v: Int = 1,
        receivedAt: Double = 1_756_800_000.123,
        host: String = AgentFixture.hostJSON
    ) -> Data {
        Data(#"{"v":\#(v),"source":"\#(source)","helper_version":1,"received_at":\#(receivedAt),"host":\#(host),"payload":\#(payload)}"#.utf8)
    }
}
