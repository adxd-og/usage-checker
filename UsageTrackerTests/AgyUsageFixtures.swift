import Foundation
@testable import Omelette

/// What `agy -p "/usage" --output-format json --print-timeout 45s` (agy 1.4.0) printed on
/// this Mac on 2026-10-16 at about 08:02 UTC, Pro plan: `proOutputText`, verbatim. Three
/// groups: Gemini Models (weekly 99.17 % left, 5-hour 98.99 %), Claude and GPT models
/// (100 % both) and Gemini 4 Argon (weekly 52.56 %). The other outputs change one thing
/// each and say what; `output(groups:)` wraps a made-up group list for the rules that
/// need one shape. 2026-10-16 and 2026-10-23 are Fridays.
enum AgyUsageFixture {
    /// 2026-10-16 08:02:02 UTC, five hours before the untouched Claude/GPT 5-hour window resets.
    static let readAt = Date(timeIntervalSince1970: 1_792_137_722)
    /// 2026-10-16 13:02:02 UTC.
    static let thirdParty5hReset = Date(timeIntervalSince1970: 1_792_155_722)
    /// 2026-10-23 08:02:02 UTC.
    static let thirdPartyWeeklyReset = Date(timeIntervalSince1970: 1_792_742_522)

    static let proOutputText = #"{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t99%\t2026-10-23T07:46:06Z\nGemini Models\tFive Hour Limit Remaining\t99%\t2026-10-16T12:46:06Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t2026-10-23T08:02:02Z\nClaude and GPT models\tFive Hour Limit Remaining\t100%\t2026-10-16T13:02:02Z\nGemini 4 Argon\tGemini 4 Argon Weekly Limit\t53%\t2026-10-23T07:45:44Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"You have used some of your weekly limit, it will fully refresh in 6 days, 23 hours.","window":"weekly","remaining_fraction":0.9916762113571167,"reset_time":"2026-10-23T07:46:06Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","description":"You have used some of your 5-hour limit, it will fully refresh in 4 hours, 44 minutes.","window":"5h","remaining_fraction":0.9899333119392395,"reset_time":"2026-10-16T12:46:06Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-23T08:02:02Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-10-16T13:02:02Z"}]},{"name":"Gemini 4 Argon","description":"For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.","buckets":[{"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","description":"You have used some of your weekly limit, it will fully refresh in 6 days, 23 hours.","window":"weekly","remaining_fraction":0.5255658626556396,"reset_time":"2026-10-23T07:45:44Z"}]}]}}}"#

    static let proOutput = Data(proOutputText.utf8)

    /// The same answer after a notice line, as a CLI may print one before its JSON.
    static let proOutputAfterANotice = Data(("A new version of agy is available.\n" + proOutputText + "\n").utf8)

    /// Ultra-shaped: the live answer without Argon's group, which Ultra plans fold into
    /// the Gemini pool (the group's own description says so).
    static let ultraOutput = output(groups: #"[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.9916762113571167,"reset_time":"2026-10-23T07:46:06Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.9899333119392395,"reset_time":"2026-10-16T12:46:06Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-23T08:02:02Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-10-16T13:02:02Z"}]}]"#)

    /// A signed-out answer, made up around agy's own sign-in message (the string is in the
    /// agy 1.4.0 binary; the status value is a guess at its shape).
    static let signedOutOutput = Data(#"{"conversation_id":"","status":"ERROR","response":"Please sign in to view available models. Launch the CLI without arguments to sign in.","num_turns":0}"#.utf8)

    /// A SUCCESS answer around `groups`, a JSON array of groups.
    static func output(groups: String) -> Data {
        Data((#"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":"# + groups + "}}}").utf8)
    }

    /// What the app publishes for `proOutput`: the four pool windows as the probe titles
    /// them, Argon as a per-model row under its group's name, in the probe's order.
    static let proBuckets: [UsageBucket] = [
        Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour",
                       percent: 100 - 0.9899333119392395 * 100, resetsAt: AntigravityFixture.gemini5hReset,
                       kind: .session, windowLength: 18_000),
        Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly",
                       percent: 100 - 0.9916762113571167 * 100, resetsAt: AntigravityFixture.geminiWeeklyReset,
                       kind: .weekly, windowLength: 604_800),
        Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini 4 Argon",
                       percent: 100 - 0.5255658626556396 * 100, resetsAt: AntigravityFixture.argonWeeklyReset,
                       kind: .modelSpecific, windowLength: 604_800),
        Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-5h", label: "Claude/GPT 5-hour",
                       percent: 0, resetsAt: thirdParty5hReset, kind: .session, windowLength: 18_000),
        Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly",
                       percent: 0, resetsAt: thirdPartyWeeklyReset, kind: .weekly, windowLength: 604_800),
    ]
}
