import XCTest
@testable import Omelette

/// The half of the status line that belongs to the session rather than to the
/// account: the model Claude Code is running and how full its context window is.
/// Exact strings, escape codes included — this is a format a terminal parses.
final class StatusLinePrefixTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func snapshot(percent: Double, resetsIn: TimeInterval?, cost: Double?, needsYou: Int, updatedAt: Date? = nil) -> StatusSnapshot {
        StatusSnapshot(
            version: 1,
            updatedAt: updatedAt ?? now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: nil,
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: percent,
                            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: "session"
                        ),
                    ],
                    todayCost: cost, weekCost: nil, todayTokens: nil, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(needsYou: needsYou, working: 0, sessions: [])
        )
    }

    private func prefix(_ model: String?, _ percent: Double?, colour: Bool = false) -> String {
        StatusLineText.sessionPrefix(model: model, contextUsedPercent: percent, colour: colour)
    }

    // MARK: - The prefix on its own

    func testTheModelAndABarOfHowFullItsContextIs() {
        XCTAssertEqual(prefix("Fable", 42.4), "Fable [####------] 42%")
    }

    /// Claude Code always sends a name; an older build, or a payload we could not
    /// read, still leaves the line something true to say.
    func testAnUnnamedModelIsCalledClaude() {
        XCTAssertEqual(prefix(nil, 42.4), "Claude [####------] 42%")
    }

    func testWithoutAContextReadingItIsJustTheModel() {
        XCTAssertEqual(prefix("Fable", nil), "Fable")
    }

    /// Run by hand in a terminal there is no session and no payload, and the line is
    /// the account's numbers alone — not the word "Claude" in front of them.
    func testWithNeitherThereIsNoPrefix() {
        XCTAssertEqual(prefix(nil, nil), "")
        XCTAssertEqual(prefix(nil, nil, colour: true), "")
    }

    func testTheBarIsTenCharactersOfNearestTenth() {
        XCTAssertEqual(prefix("Fable", 0), "Fable [----------] 0%")
        XCTAssertEqual(prefix("Fable", 4), "Fable [----------] 4%")
        XCTAssertEqual(prefix("Fable", 5), "Fable [#---------] 5%")
        XCTAssertEqual(prefix("Fable", 50), "Fable [#####-----] 50%")
        XCTAssertEqual(prefix("Fable", 99.6), "Fable [##########] 100%")
        XCTAssertEqual(prefix("Fable", 100), "Fable [##########] 100%")
    }

    // MARK: - Colours

    private let cyan = "\u{1B}[2;36m"
    private let green = "\u{1B}[2;32m"
    private let yellow = "\u{1B}[2;33m"
    private let red = "\u{1B}[2;31m"
    private let dim = "\u{1B}[2m"
    private let reset = "\u{1B}[0m"

    func testTheColouredPrefixIsDimCyanForTheModelAndDimForThePercent() {
        XCTAssertEqual(
            prefix("Fable", 42.4, colour: true),
            "\(cyan)Fable\(reset) \(green)[####------]\(reset) \(dim)42%\(reset)"
        )
        XCTAssertEqual(prefix("Fable", nil, colour: true), "\(cyan)Fable\(reset)")
    }

    /// Green while there is room, yellow from half full, red from 80% — the point at
    /// which the session is going to start dropping context.
    func testTheBarChangesColourAtFiftyAndAtEighty() {
        XCTAssertTrue(prefix("Fable", 49.9, colour: true).contains(green))
        XCTAssertTrue(prefix("Fable", 50, colour: true).contains(yellow))
        XCTAssertTrue(prefix("Fable", 79.9, colour: true).contains(yellow))
        XCTAssertTrue(prefix("Fable", 80, colour: true).contains(red))
        XCTAssertTrue(prefix("Fable", 100, colour: true).contains(red))
    }

    /// A file, a pipe into `grep`, or a status bar that does not read escape codes.
    func testWithoutColourThereIsNotAnEscapeCodeInTheLine() {
        let line = StatusLineText.render(
            snapshot: snapshot(percent: 61, resetsIn: 88 * 60, cost: 386.64, needsYou: 1),
            now: now,
            input: StatusLineInput(model: "Fable", contextUsedPercent: 42.4),
            colour: false
        )
        XCTAssertFalse(line.contains("\u{1B}"), line)
    }

    // MARK: - In front of the account's numbers

    func testTheWholeLine() {
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(percent: 61, resetsIn: 88 * 60, cost: 386.64, needsYou: 1),
                now: now,
                input: StatusLineInput(model: "Fable", contextUsedPercent: 42.4),
                colour: false
            ),
            "Fable [####------] 42% · ◐ 61% · resets in 1h 28m · ≈$386.64 today · ⚑ 1"
        )
    }

    func testTheColouredPrefixIsJoinedToPlainNumbers() {
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(percent: 61, resetsIn: nil, cost: nil, needsYou: 0),
                now: now,
                input: StatusLineInput(model: "Fable", contextUsedPercent: 42.4)
            ),
            "\(cyan)Fable\(reset) \(green)[####------]\(reset) \(dim)42%\(reset) · ◐ 61%"
        )
    }

    /// Omelette closed, or ten minutes without a poll: the account's numbers are a
    /// guess and go away, but the session's are the session's and still true.
    func testAMissingOrStaleSnapshotLeavesThePrefixStanding() {
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: nil, now: now,
                input: StatusLineInput(model: "Fable", contextUsedPercent: 42.4), colour: false
            ),
            "Fable [####------] 42%"
        )
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(percent: 61, resetsIn: 88 * 60, cost: 386.64, needsYou: 1, updatedAt: now.addingTimeInterval(-601)),
                now: now,
                input: StatusLineInput(model: "Fable", contextUsedPercent: nil), colour: false
            ),
            "Fable"
        )
    }

    func testNoPayloadAndNoSnapshotIsStillAnEmptyLine() {
        XCTAssertEqual(StatusLineText.render(snapshot: nil, now: now, input: .none), "")
    }

    /// The context bar counts what is used whichever way the app is showing its
    /// rate-limit windows: they are different quantities, and "58% left" of a context
    /// window is not a limit anybody has.
    func testTheContextBarIgnoresTheRemainingSetting() {
        var remaining = snapshot(percent: 61, resetsIn: nil, cost: nil, needsYou: 0)
        remaining.showsRemaining = true

        XCTAssertEqual(
            StatusLineText.render(
                snapshot: remaining, now: now,
                input: StatusLineInput(model: "Fable", contextUsedPercent: 42.4), colour: false
            ),
            "Fable [####------] 42% · ◐ 39% left"
        )
    }
}
