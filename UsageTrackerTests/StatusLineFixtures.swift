import Foundation

/// The JSON Claude Code 2.1.316 pipes into `brioche statusline`, built the way its
/// binary builds it (read by the session, 2026-11-02): `rate_limits` is
/// `{five_hour: {used_percentage, resets_at}, seven_day: {…}}`, each window present
/// only when known, `used_percentage` rounded to one decimal
/// (`Math.min(Math.round(utilization * 1000) / 10, 100)`), `resets_at` in epoch
/// seconds. A gateway adds `spend_limit` beside them; nothing else does. Ids and
/// paths are made up; the shape is not.
enum StatusLineFixture {
    static let sessionID = "0f3a5c1e-7b2d-4a91-8c6f-2d5e9b0a4c73"
    static let promptID = "6a1d2e3f-4b5c-4d6e-8f70-91a2b3c4d5e6"

    /// 2026-09-06 14:00:00 UTC, a Sunday.
    static let fiveHourResetsAt = Date(timeIntervalSince1970: 1_788_703_200)
    /// 2026-09-10 18:40:00 UTC, a Thursday.
    static let sevenDayResetsAt = Date(timeIntervalSince1970: 1_789_065_600)

    /// Both windows known: 23.5 % of the five hours, 41.2 % of the week.
    static let rateLimits = #"{"five_hour":{"used_percentage":23.5,"resets_at":1788703200},"seven_day":{"used_percentage":41.2,"resets_at":1789065600}}"#

    /// The whole payload. `rateLimits` is the raw JSON of `rate_limits`; nil leaves the
    /// key out, as Claude Code does before the session's first API response and on a
    /// plan without limits. The model and the context window are the ones the
    /// end-to-end tests already print: `Opus [####------] 42%`.
    static func payload(
        sessionID: String = StatusLineFixture.sessionID,
        rateLimits: String? = StatusLineFixture.rateLimits
    ) -> String {
        let limits = rateLimits.map { #","rate_limits":"# + $0 } ?? ""
        return """
        {"hook_event_name":"Status","session_id":"\(sessionID)","prompt_id":"\(promptID)",\
        "transcript_path":"~/.claude/projects/-Desktop-Usage-tracker/0f3a5c1e.jsonl",\
        "cwd":"~/Desktop/Usage tracker",\
        "model":{"id":"claude-opus-5","display_name":"Opus"},\
        "workspace":{"current_dir":"~/Desktop/Usage tracker","project_dir":"~/Desktop/Usage tracker"},\
        "version":"2.1.316","output_style":{"name":"default"},\
        "cost":{"total_cost_usd":1.23,"total_duration_ms":42000,"total_api_duration_ms":18250,\
        "total_lines_added":12,"total_lines_removed":3},\
        "exceeds_200k_tokens":false,\
        "context_window":{"used_percentage":42.4,"remaining_percentage":57.6}\(limits)}
        """
    }
}
