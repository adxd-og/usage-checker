import Foundation
@testable import Omelette

/// Line builders for Codex rollout fixtures, in the exact JSON shapes
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` uses. Field names,
/// nesting and key order are copied from this Mac's own rollouts (Codex CLI 0.146.0,
/// 0.153.0 and 0.153.4, read 2026-09-10); ids and paths are scrubbed.
///
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § Facts (Codex).
enum CodexRollout {
    /// Immutable and only ever asked to format, which `ISO8601DateFormatter` is
    /// documented to be safe for; `nonisolated(unsafe)` because an `enum` has no
    /// instance to hang it off.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func stamp(_ date: Date) -> String { iso.string(from: date) }

    /// Line 1 of every rollout. `originator` is what `SessionSummary.origin` carries.
    static func sessionMeta(
        sessionID: String,
        threadID: String? = nil,
        cwd: String,
        originator: String = "codex_exec",
        cliVersion: String = "0.153.4",
        at date: Date
    ) -> String {
        """
        {"timestamp":"\(stamp(date))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"\(sessionID)","id":"\(threadID ?? sessionID)",\
        "timestamp":"\(stamp(date))","cwd":"\(cwd)","originator":"\(originator)",\
        "cli_version":"\(cliVersion)","source":"exec","thread_source":"user",\
        "model_provider":"openai","parent_thread_id":null,"agent_nickname":null,\
        "agent_path":null}}
        """
    }

    /// Line 1 of a sub-agent rollout: `session_id` is the PARENT's, `id` is its own.
    static func subagentMeta(
        sessionID: String,
        threadID: String,
        parentThreadID: String,
        nickname: String?,
        agentPath: String?,
        cwd: String,
        originator: String = "codex_exec",
        at date: Date
    ) -> String {
        let nick = nickname.map { "\"\($0)\"" } ?? "null"
        let path = agentPath.map { "\"\($0)\"" } ?? "null"
        return """
        {"timestamp":"\(stamp(date))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"\(sessionID)","id":"\(threadID)","timestamp":"\(stamp(date))",\
        "cwd":"\(cwd)","originator":"\(originator)","source":{"subagent":\
        {"thread_spawn":{"parent_thread_id":"\(parentThreadID)","depth":1,\
        "agent_path":\(path),"agent_nickname":\(nick),"agent_role":null}}},\
        "thread_source":"subagent","cli_version":"0.153.4",\
        "parent_thread_id":"\(parentThreadID)","agent_nickname":\(nick),\
        "agent_path":\(path)}}
        """
    }

    /// `cwd: nil` omits the field, for the project-fallback tests.
    static func turnContext(
        turnID: String = "01a07092-9ea2-7c40-8c17-f322bdc84723",
        model: String,
        effort: String? = nil,
        cwd: String?,
        at date: Date
    ) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\",\"workspace_roots\":[\"\($0)\"]," } ?? ""
        let effortField = effort.map { "\"effort\":\"\($0)\"," } ?? ""
        return """
        {"timestamp":"\(stamp(date))","ordinal":7,"type":"turn_context","payload":\
        {"turn_id":"\(turnID)","root_turn_id":"\(turnID)",\(cwdField)\
        "current_date":"2026-09-06","timezone":"Europe/Vilnius","approval_policy":"never",\
        "model":"\(model)",\(effortField)"summary":"auto","personality":"pragmatic"}}
        """
    }

    /// One cumulative reading. `last_token_usage` is written the way the CLI writes it
    /// and is deliberately ignored by the parser.
    static func tokenCount(
        at date: Date, input: Int, cached: Int, cacheWrite: Int = 0, output: Int, reasoning: Int
    ) -> String {
        let counters = "\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"cache_write_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)," +
            "\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(input + output)"
        return """
        {"timestamp":"\(stamp(date))","ordinal":18,"type":"event_msg","payload":\
        {"type":"token_count","info":{"total_token_usage":{\(counters)},\
        "last_token_usage":{\(counters)},"model_context_window":258400},\
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":72.0,\
        "window_minutes":43200,"resets_at":1790937107}}}}
        """
    }

    static func nullInfoTokenCount(at date: Date) -> String {
        """
        {"timestamp":"\(stamp(date))","ordinal":16,"type":"event_msg","payload":\
        {"type":"token_count","info":null,"rate_limits":null}}
        """
    }

    /// One API response's own usage — written BEFORE that response's `token_count`.
    static func record(
        at date: Date,
        threadID: String,
        sessionID: String? = nil,
        turnID: String = "01a07092-9ea2-7c40-8c17-f322bdc84723",
        responseID: String,
        input: Int, cached: Int, cacheWrite: Int = 0, output: Int, reasoning: Int
    ) -> String {
        let usage = "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"cache_write_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)," +
            "\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(input + output)}"
        return """
        {"timestamp":"\(stamp(date))","ordinal":13,"type":"token_usage_record","payload":\
        {"thread_id":"\(threadID)","turn_id":"\(turnID)",\
        "session_id":"\(sessionID ?? threadID)","root_turn_id":"\(turnID)",\
        "response_id":"\(responseID)","usage":\(usage),"turn_token_usage":\(usage),\
        "thread_token_usage":\(usage)}}
        """
    }

    /// The compaction marker. Its `latest_token_usage_record` is a verbatim copy of a
    /// `token_usage_record` payload and must never be billed.
    static func compacted(
        at date: Date,
        threadID: String,
        turnID: String = "01a07092-9ea2-7c40-8c17-f322bdc84723",
        responseID: String,
        input: Int, cached: Int, cacheWrite: Int = 0, output: Int, reasoning: Int
    ) -> String {
        let usage = "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"cache_write_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)," +
            "\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(input + output)}"
        return """
        {"timestamp":"\(stamp(date))","ordinal":226,"type":"compacted","payload":\
        {"message":"compacted","window_number":2,"window_id":"w2",\
        "compaction_response_id":"\(responseID)","latest_token_usage_record":\
        {"thread_id":"\(threadID)","turn_id":"\(turnID)","session_id":"\(threadID)",\
        "root_turn_id":"\(turnID)","response_id":"\(responseID)","usage":\(usage),\
        "turn_token_usage":\(usage),"thread_token_usage":\(usage)}}}
        """
    }

    /// A user-role `response_item`. `kinds: nil` omits the metadata object entirely,
    /// which is the shape the AGENTS.md / environment preamble records do NOT have.
    static func userMessage(at date: Date, text: String, kinds: [String]?) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let meta = kinds.map { list -> String in
            let items = list.map { "\"\($0)\"" }.joined(separator: ",")
            return ",\"internal_chat_message_metadata_passthrough\":"
                + "{\"turn_id\":\"01a07092-9ea2-7c40-8c17-f322bdc84723\","
                + "\"create_time\":1788685979.279051,\"content_item_kinds\":[\(items)]}"
        } ?? ""
        return """
        {"timestamp":"\(stamp(date))","ordinal":9,"type":"response_item","payload":\
        {"type":"message","id":"msg_01a075fe-0e8f-7a51-9e22-5c28c4260f16","role":"user",\
        "content":[{"type":"input_text","text":"\(escaped)"}]\(meta)}}
        """
    }

    /// One `~/.codex/session_index.jsonl` line.
    static func indexLine(id: String, name: String, updatedAt: String) -> String {
        "{\"id\":\"\(id)\",\"thread_name\":\"\(name)\",\"updated_at\":\"\(updatedAt)\"}"
    }
}

/// A `~/.codex`-shaped temp tree: `sessions/YYYY/MM/DD/…`, `archived_sessions/…` and
/// `session_index.jsonl` as siblings, so the aggregator derives the last two from the
/// injected sessions root exactly the way it does in production.
struct CodexTree {
    let home: URL
    var sessions: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    var archived: URL { home.appendingPathComponent("archived_sessions", isDirectory: true) }
    var index: URL { home.appendingPathComponent("session_index.jsonl") }

    init(under parent: URL) throws {
        home = parent.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    @discardableResult
    func writeRollout(
        _ lines: [String], day: String = "2026/09/06", named name: String
    ) throws -> URL {
        let dir = sessions.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func writeArchived(_ lines: [String], named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let url = archived.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeIndex(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: index, atomically: true, encoding: .utf8)
    }

    func aggregator(calendar: Calendar = .current) -> CodexUsageAggregator {
        CodexUsageAggregator(rootURL: sessions, calendar: calendar)
    }
}
