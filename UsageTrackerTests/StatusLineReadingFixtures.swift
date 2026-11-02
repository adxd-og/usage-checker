import Foundation
@testable import Omelette

/// A drop file's reading as the app reads it back (`StatusLineDrop.Reading`), with the
/// payload fixture's values: 23.5 % of the five hours, 41.2 % of the week, the session
/// and prompt ids of `StatusLineFixture`, 18 250 ms of API time, the default Claude
/// folder of a made-up home. Each test moves only what it is about: a counter, the time,
/// a window, the folder, the format.
extension StatusLineFixture {
    /// The home every reading here belongs to; never touched on disk.
    static let home = URL(fileURLWithPath: "/tmp/StatusLineFixture-home", isDirectory: true)
    /// `~/.claude` of `home`, spelled as `StatusLineDrop.configDir` spells it.
    static let configDir = "/tmp/StatusLineFixture-home/.claude"
    static let fiveHour = StatusLineInput.RateLimits.Window(usedPercent: 23.5, resetsAt: fiveHourResetsAt)
    static let sevenDay = StatusLineInput.RateLimits.Window(usedPercent: 41.2, resetsAt: sevenDayResetsAt)

    static func reading(
        sessionID: String = StatusLineFixture.sessionID,
        promptID: String? = StatusLineFixture.promptID,
        totalAPIDurationMs: Double? = 18_250,
        fiveHour: StatusLineInput.RateLimits.Window? = StatusLineFixture.fiveHour,
        sevenDay: StatusLineInput.RateLimits.Window? = StatusLineFixture.sevenDay,
        writtenAt: Date,
        configDir: String = StatusLineFixture.configDir,
        formatVersion: Int = StatusLineDrop.Reading.currentFormatVersion
    ) -> StatusLineDrop.Reading {
        StatusLineDrop.Reading(
            formatVersion: formatVersion,
            sessionID: sessionID,
            promptID: promptID,
            totalAPIDurationMs: totalAPIDurationMs,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            writtenAt: writtenAt,
            configDir: configDir
        )
    }
}
