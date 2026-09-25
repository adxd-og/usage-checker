import XCTest
@testable import Omelette

/// Independent verification of `fix/3.0-followups` package contract item 3:
/// `PopoverCopy.metaLine(service:fetchedAt:now:)` reads through `UpdatedCopy.text` —
/// "Just updated" under 5 s (never "Updated just now"), "Updated 12s ago",
/// "Never updated" for a zero-epoch `fetchedAt` — and a provider tab reads
/// "<name> <plan> · <updated>". `PopoverCopyTests.swift`'s own new assertion compares
/// `metaLine`'s output against `UpdatedCopy.text`'s output, which is tautological (the
/// same function on both sides); this file pins the literal words instead.
final class UpdatedCopyMetaLineVerificationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func after(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    // MARK: - UpdatedCopy.text, the literal words

    func testUnderFiveSecondsReadsJustUpdatedNeverUpdatedJustNow() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(0)), "Just updated")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(4.9)), "Just updated")
    }

    /// The boundary the code draws: `delta < 5` is "Just updated", so exactly 5s must
    /// already read as a count, not fall on the wrong side by an off-by-one.
    func testFiveSecondsExactlyIsAlreadyACount() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(5)), "Updated 5s ago")
    }

    func testTwelveSecondsReadsAsACount() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(12)), "Updated 12s ago")
    }

    func testAZeroEpochFetchedAtReadsNeverUpdated() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: Date(timeIntervalSince1970: 0), now: epoch), "Never updated")
    }

    /// `fetchedAt.timeIntervalSince1970 < 1` is the guard, so a sub-second epoch also
    /// counts as "never" — the boundary is "at least one full second past the epoch",
    /// not "exactly zero".
    func testASubSecondEpochAlsoReadsNeverUpdated() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: Date(timeIntervalSince1970: 0.5), now: epoch), "Never updated")
    }

    func testAClockThatRanBackwardsStillReadsJustUpdated() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(-45)), "Just updated",
                       "a negative delta must clamp to zero, not print a negative count")
    }

    func testMinutesAndHoursRoundDownToWholeUnits() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(125)), "Updated 2m ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: epoch, now: after(7300)), "Updated 2h ago")
    }

    // MARK: - PopoverCopy.metaLine

    func testTheAllTabsMetaLineIsJustTheAgeUnderFiveSeconds() {
        XCTAssertEqual(PopoverCopy.metaLine(service: nil, fetchedAt: epoch, now: after(0)), "Just updated")
    }

    func testTheAllTabsMetaLineIsNeverUpdatedBeforeTheFirstReading() {
        XCTAssertEqual(
            PopoverCopy.metaLine(service: nil, fetchedAt: Date(timeIntervalSince1970: 0), now: epoch),
            "Never updated"
        )
    }

    /// "<name> <plan> · <updated>" — the exact literal the spec names, independent
    /// fixture from `PopoverCopyTests.swift`'s own provider-tab test.
    func testAProviderTabReadsNamePlanDotUpdated() {
        let service = Fixture.snapshot(id: "codex", displayName: "Codex", plan: "Codex Plus", at: epoch)
        XCTAssertEqual(
            PopoverCopy.metaLine(service: service, fetchedAt: epoch, now: after(12)),
            "Codex Plus · Updated 12s ago"
        )
    }

    func testAProviderTabWithNoPlanReadsJustItsNameDotUpdated() {
        let service = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: nil, at: epoch)
        XCTAssertEqual(
            PopoverCopy.metaLine(service: service, fetchedAt: epoch, now: after(0)),
            "Antigravity · Just updated"
        )
    }

    // MARK: - Source scan: the retired spelling stays retired

    /// Independent of `PopoverCopy.updatedText`'s own removal (confirmed by the build
    /// no longer compiling a reference to it): the *string* "Updated just now" must not
    /// survive anywhere else either — a stray literal, a comment nobody updated, a
    /// second copy of the old rule.
    func testTheStringUpdatedJustNowDoesNotSurviveUnderTheAppOrCLICore() throws {
        var repo = URL(fileURLWithPath: #filePath)
        repo.deleteLastPathComponent()
        repo.deleteLastPathComponent()
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        for relative in ["UsageTracker", "CLICore"] {
            let root = repo.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                XCTAssertFalse(
                    contents.contains("Updated just now"),
                    "\(fileURL.lastPathComponent) still spells the retired \"Updated just now\""
                )
            }
        }
    }
}
