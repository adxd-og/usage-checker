import CodexBarCore
import Foundation

/// What CodexBarCore's Antigravity probe hands `AntigravityProvider`, built from
/// CodexBarCore's public value types: the probe's quota-summary snapshot itself cannot
/// be built from a test. Each payload is the `UsageSnapshot` its `toUsageSnapshot()`
/// returns, windows in the probe's order. Percentages and resets are this Mac's
/// 2026-10-16 readings on a Pro plan (`status.json` for the quota summary,
/// `history.jsonl` 07:50:14 and 08:02:22 for the per-model path). The Ultra payload is
/// the same shape without Argon's group, which the live payload's description says
/// Ultra plans fold into the Gemini pool; its figures are made up.
enum AntigravityFixture {
    /// 2026-10-16 07:50:14 UTC, the per-model reading.
    static let readAt = Date(timeIntervalSince1970: 1_792_137_014)
    /// 2026-10-16 12:46:06 UTC.
    static let gemini5hReset = Date(timeIntervalSince1970: 1_792_154_766)
    /// 2026-10-23 07:46:06 UTC.
    static let geminiWeeklyReset = Date(timeIntervalSince1970: 1_792_741_566)
    /// 2026-10-23 07:45:44 UTC.
    static let argonWeeklyReset = Date(timeIntervalSince1970: 1_792_741_544)
    /// 2026-10-16 13:06:23 UTC.
    static let thirdParty5hReset = Date(timeIntervalSince1970: 1_792_155_983)
    /// 2026-10-23 08:06:23 UTC.
    static let thirdPartyWeeklyReset = Date(timeIntervalSince1970: 1_792_742_783)

    /// A quota-summary window as the probe builds it: id `antigravity-quota-summary-`
    /// plus the server's bucket id, title "<group> <cadence>", minutes 300 or 10080.
    static func summaryWindow(
        bucketID: String,
        title: String,
        percent: Double,
        minutes: Int?,
        resetsAt: Date?,
        usageKnown: Bool = true
    ) -> NamedRateWindow {
        NamedRateWindow(
            id: "antigravity-quota-summary-" + bucketID,
            title: title,
            window: RateWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: resetsAt, resetDescription: nil),
            usageKnown: usageKnown
        )
    }

    /// A per-model window as the probe builds it: the model's wire id, the server's
    /// label, no window length.
    static func modelWindow(
        id: String,
        title: String,
        percent: Double,
        resetsAt: Date?,
        usageKnown: Bool = true
    ) -> NamedRateWindow {
        NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(usedPercent: percent, windowMinutes: nil, resetsAt: resetsAt, resetDescription: nil),
            usageKnown: usageKnown
        )
    }

    static func usage(
        primary: RateWindow?,
        secondary: RateWindow?,
        windows: [NamedRateWindow]
    ) -> CodexBarCore.UsageSnapshot {
        CodexBarCore.UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: windows.isEmpty ? nil : windows,
            updatedAt: readAt
        )
    }

    /// Pro, quota summary, three groups: Gemini Models, Claude and GPT models, Gemini 4
    /// Argon. CodexBarCore titles every gemini group "Gemini", so Argon's weekly is a
    /// second "Gemini weekly".
    static let proSummaryWindows: [NamedRateWindow] = [
        summaryWindow(bucketID: "gemini-5h", title: "Gemini 5-hour", percent: 0.035733,
                      minutes: 300, resetsAt: gemini5hReset),
        summaryWindow(bucketID: "gemini-weekly", title: "Gemini weekly", percent: 0.01021,
                      minutes: 10080, resetsAt: geminiWeeklyReset),
        summaryWindow(bucketID: "gemini-argon-wtu-weekly", title: "Gemini weekly", percent: 44.32,
                      minutes: 10080, resetsAt: argonWeeklyReset),
        summaryWindow(bucketID: "3p-5h", title: "Claude/GPT 5-hour", percent: 0,
                      minutes: 300, resetsAt: thirdParty5hReset),
        summaryWindow(bucketID: "3p-weekly", title: "Claude/GPT weekly", percent: 0,
                      minutes: 10080, resetsAt: thirdPartyWeeklyReset),
    ]

    /// `primary` is the worst gemini-titled window (Argon's); `secondary` the worst
    /// Claude/GPT one, the 5-hour on the 0% tie (alphabetically first title).
    static let proSummary = usage(
        primary: proSummaryWindows[2].window,
        secondary: proSummaryWindows[3].window,
        windows: proSummaryWindows
    )

    /// Ultra-shaped quota summary: the two pools only.
    static let ultraSummaryWindows: [NamedRateWindow] = [
        summaryWindow(bucketID: "gemini-5h", title: "Gemini 5-hour", percent: 12.5,
                      minutes: 300, resetsAt: gemini5hReset),
        summaryWindow(bucketID: "gemini-weekly", title: "Gemini weekly", percent: 30,
                      minutes: 10080, resetsAt: geminiWeeklyReset),
        summaryWindow(bucketID: "3p-5h", title: "Claude/GPT 5-hour", percent: 0,
                      minutes: 300, resetsAt: thirdParty5hReset),
        summaryWindow(bucketID: "3p-weekly", title: "Claude/GPT weekly", percent: 4,
                      minutes: 10080, resetsAt: thirdPartyWeeklyReset),
    ]

    static let ultraSummary = usage(
        primary: ultraSummaryWindows[1].window,
        secondary: ultraSummaryWindows[3].window,
        windows: ultraSummaryWindows
    )

    /// Per-model path (web fallback, older servers): the pool aggregates from the
    /// pools' own models, and Argon, an unknown family, as three effort variants with
    /// placeholder wire ids and no window length, listed High, Medium, Low.
    static func perModelArgon(percent: Double) -> CodexBarCore.UsageSnapshot {
        usage(
            primary: RateWindow(usedPercent: 0.035733, windowMinutes: nil, resetsAt: gemini5hReset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: thirdParty5hReset, resetDescription: nil),
            windows: [
                modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)", percent: percent,
                            resetsAt: argonWeeklyReset),
                modelWindow(id: "MODEL_PLACEHOLDER_M418", title: "Gemini 4 Argon (Medium)", percent: percent,
                            resetsAt: argonWeeklyReset),
                modelWindow(id: "MODEL_PLACEHOLDER_M417", title: "Gemini 4 Argon (Low)", percent: percent,
                            resetsAt: argonWeeklyReset),
            ]
        )
    }

    /// History 07:50:14: Argon's variants at 6.12%.
    static let perModel0750 = perModelArgon(percent: 6.11776)
    /// History 08:02:22: Argon's variants at 47.44%, the Gemini pool still at 0.04%.
    static let perModel0802 = perModelArgon(percent: 47.443414)
}
