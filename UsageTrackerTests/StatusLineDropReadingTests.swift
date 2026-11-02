import XCTest
@testable import Omelette

/// What a drop file says (spec 2026-11-02 Claude limits from the status line,
/// § Design › Wire): `{v: 1, session_id, prompt_id, total_api_duration_ms, five_hour?,
/// seven_day?, written_at, config_dir}`, made only from a payload with a session id and
/// at least one window. Pure: nothing here touches a disk.
final class StatusLineDropReadingTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private let home = URL(fileURLWithPath: "/tmp/StatusLineDropReadingTests-home", isDirectory: true)
    private let configDir = "/tmp/StatusLineDropReadingTests-home/.claude"

    private let fiveHour = StatusLineInput.RateLimits.Window(
        usedPercent: 23.5, resetsAt: StatusLineFixture.fiveHourResetsAt
    )
    private let sevenDay = StatusLineInput.RateLimits.Window(
        usedPercent: 41.2, resetsAt: StatusLineFixture.sevenDayResetsAt
    )

    private func input(
        rateLimits: StatusLineInput.RateLimits?,
        sessionID: String? = StatusLineFixture.sessionID,
        promptID: String? = StatusLineFixture.promptID,
        totalAPIDurationMs: Double? = 18_250
    ) -> StatusLineInput {
        StatusLineInput(
            model: "Opus",
            contextUsedPercent: 42.4,
            rateLimits: rateLimits,
            sessionID: sessionID,
            promptID: promptID,
            totalAPIDurationMs: totalAPIDurationMs,
            version: "2.1.316"
        )
    }

    private func both() -> StatusLineInput.RateLimits {
        StatusLineInput.RateLimits(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private func json(_ reading: StatusLineDrop.Reading) throws -> [String: Any] {
        let data = try StatusLineDrop.encoder.encode(reading)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAReadingCarriesTheWindowsTheCountersTheTimeAndTheConfigDir() {
        XCTAssertEqual(
            StatusLineDrop.reading(from: input(rateLimits: both()), now: now, configDir: configDir),
            StatusLineDrop.Reading(
                formatVersion: 1,
                sessionID: StatusLineFixture.sessionID,
                promptID: StatusLineFixture.promptID,
                totalAPIDurationMs: 18_250,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                writtenAt: now,
                configDir: configDir
            )
        )
    }

    /// The parser and the drop agree: Claude Code's own payload makes the reading above.
    func testThePayloadClaudeCodeWritesMakesThatReading() {
        XCTAssertEqual(
            StatusLineDrop.reading(
                from: StatusLineInput.parse(Data(StatusLineFixture.payload().utf8)),
                now: now,
                configDir: configDir
            ),
            StatusLineDrop.reading(from: input(rateLimits: both()), now: now, configDir: configDir)
        )
    }

    /// One window is a reading. A counter the payload lacked stays missing rather than
    /// becoming a zero the app would compare against.
    func testOneWindowIsEnoughAndAMissingCounterStaysMissing() {
        let reading = StatusLineDrop.reading(
            from: input(
                rateLimits: StatusLineInput.RateLimits(fiveHour: nil, sevenDay: sevenDay),
                promptID: nil,
                totalAPIDurationMs: nil
            ),
            now: now,
            configDir: configDir
        )

        XCTAssertEqual(reading?.sessionID, StatusLineFixture.sessionID)
        XCTAssertEqual(reading?.sevenDay, sevenDay)
        XCTAssertNil(reading?.fiveHour)
        XCTAssertNil(reading?.promptID)
        XCTAssertNil(reading?.totalAPIDurationMs)
    }

    func testNoWindowOrNoSessionIsNoReading() {
        XCTAssertNil(StatusLineDrop.reading(from: input(rateLimits: nil), now: now, configDir: configDir))
        XCTAssertNil(
            StatusLineDrop.reading(
                from: input(rateLimits: StatusLineInput.RateLimits(fiveHour: nil, sevenDay: nil)),
                now: now,
                configDir: configDir
            )
        )
        XCTAssertNil(
            StatusLineDrop.reading(from: input(rateLimits: both(), sessionID: nil), now: now, configDir: configDir)
        )
        XCTAssertNil(StatusLineDrop.reading(from: StatusLineInput.none, now: now, configDir: configDir))
    }

    /// The folder Claude Code keeps the session's account in, so the app can bind a
    /// reading to it: `CLAUDE_CONFIG_DIR` when it is set, else `~/.claude`, one spelling
    /// per folder.
    func testTheConfigDirIsClaudeConfigDirOrTheDefault() {
        let fallback = "/tmp/StatusLineDropReadingTests-home/.claude"
        XCTAssertEqual(StatusLineDrop.configDir(environment: [:], home: home), fallback)
        XCTAssertEqual(StatusLineDrop.configDir(environment: ["CLAUDE_CONFIG_DIR": ""], home: home), fallback)
        XCTAssertEqual(StatusLineDrop.configDir(environment: ["CLAUDE_CONFIG_DIR": "   "], home: home), fallback)
        XCTAssertEqual(
            StatusLineDrop.configDir(environment: ["CLAUDE_CONFIG_DIR": "/tmp/work-claude"], home: home),
            "/tmp/work-claude"
        )
        XCTAssertEqual(
            StatusLineDrop.configDir(environment: ["CLAUDE_CONFIG_DIR": "/tmp/work-claude/"], home: home),
            "/tmp/work-claude",
            "one spelling per folder, so the app can compare"
        )
        XCTAssertEqual(
            StatusLineDrop.configDir(environment: ["CLAUDE_CONFIG_DIR": "/tmp/x/../work-claude/."], home: home),
            "/tmp/work-claude"
        )
    }

    /// The keys the app's reader decodes, spelled as the spec spells them; times in
    /// epoch seconds, as Claude Code writes `resets_at`.
    func testTheFileSpellsTheWireFormat() throws {
        let reading = try XCTUnwrap(
            StatusLineDrop.reading(from: input(rateLimits: both()), now: now, configDir: configDir)
        )
        let object = try json(reading)

        XCTAssertEqual(
            Set(object.keys),
            ["v", "session_id", "prompt_id", "total_api_duration_ms", "five_hour", "seven_day", "written_at", "config_dir"]
        )
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["session_id"] as? String, StatusLineFixture.sessionID)
        XCTAssertEqual(object["prompt_id"] as? String, StatusLineFixture.promptID)
        XCTAssertEqual(object["total_api_duration_ms"] as? Double, 18_250)
        XCTAssertEqual(object["written_at"] as? Double, 1_788_693_600)
        XCTAssertEqual(object["config_dir"] as? String, configDir)
        let five = try XCTUnwrap(object["five_hour"] as? [String: Any])
        XCTAssertEqual(Set(five.keys), ["used_percentage", "resets_at"])
        XCTAssertEqual(five["used_percentage"] as? Double, 23.5)
        XCTAssertEqual(five["resets_at"] as? Double, 1_788_703_200)
        let seven = try XCTUnwrap(object["seven_day"] as? [String: Any])
        XCTAssertEqual(seven["used_percentage"] as? Double, 41.2)
        XCTAssertEqual(seven["resets_at"] as? Double, 1_789_065_600)
    }

    /// Absent, never `null`: a reader has one way to see "not known".
    func testAnAbsentWindowOrCounterIsAnAbsentKey() throws {
        let reading = try XCTUnwrap(
            StatusLineDrop.reading(
                from: input(
                    rateLimits: StatusLineInput.RateLimits(fiveHour: nil, sevenDay: sevenDay),
                    promptID: nil,
                    totalAPIDurationMs: nil
                ),
                now: now,
                configDir: configDir
            )
        )

        XCTAssertEqual(Set(try json(reading).keys), ["v", "session_id", "seven_day", "written_at", "config_dir"])
    }

    func testTheFileReadsBackAsTheSameReading() throws {
        let reading = try XCTUnwrap(
            StatusLineDrop.reading(from: input(rateLimits: both()), now: now, configDir: configDir)
        )

        XCTAssertEqual(
            try StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: StatusLineDrop.encoder.encode(reading)),
            reading
        )
    }
}
