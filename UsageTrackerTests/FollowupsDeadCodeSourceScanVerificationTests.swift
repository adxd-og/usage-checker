import XCTest
@testable import Omelette

/// Independent verification of `fix/3.0-followups` package contract item 5: dead code
/// removed with its tests — `OverviewView.burnLine`, `SessionListRule.isWide` /
/// `minimumWideWidth`, `SessionCopy.listHeader` / `listColumns`,
/// `AgentsSettingsText.hookStatusTint` — while `OverviewCopy.burnLine`,
/// `SettingsView.usageSummary` and `SessionCopy.subAgentsTitle(count:)` stay.
///
/// Scans the actual tracked sources under `UsageTracker`, `CLICore` and
/// `UsageTrackerTests` with `git grep` (as `GeminiRemovalSourceScanVerificationTests`
/// does), so it catches a stray reference no unit test calls — dead code left dead but
/// un-deleted, a doc comment nobody updated, a re-added helper with the same name.
final class FollowupsDeadCodeSourceScanVerificationTests: XCTestCase {
    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        return url
    }

    /// `git grep -c` over exactly `UsageTracker`, `CLICore`, `UsageTrackerTests` (the
    /// three directories the package contract names). Returns the number of matching
    /// lines; 0 when the pattern is absent, which `git grep` reports as exit status 1
    /// (not a real error — anything above 1 is).
    ///
    /// Excludes this test file's own path: its doc comment above necessarily *names*
    /// every symbol under test, including the ones asserted gone, so scanning it too
    /// would make the "gone" assertions fail against this file's own prose rather than
    /// against the dead code they are meant to catch.
    private func matchCount(_ pattern: String, extendedRegex: Bool = false, in repo: URL) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var arguments = ["grep", "-c"]
        if extendedRegex { arguments.append("-E") }
        arguments.append(pattern)
        arguments.append(contentsOf: [
            "--", "UsageTracker", "CLICore", "UsageTrackerTests",
            ":(exclude)UsageTrackerTests/FollowupsDeadCodeSourceScanVerificationTests.swift",
        ])
        process.arguments = arguments
        process.currentDirectoryURL = repo
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertLessThanOrEqual(process.terminationStatus, 1, "git grep itself failed (status \(process.terminationStatus)) for \(pattern)")

        let output = String(decoding: data, as: UTF8.self)
        guard !output.isEmpty else { return 0 }
        // "path:count" per matching file; sum the counts.
        return output.split(separator: "\n").reduce(0) { total, line in
            let parts = line.split(separator: ":")
            return total + (parts.last.flatMap { Int($0) } ?? 0)
        }
    }

    // MARK: - Gone, qualified so the still-live namesakes cannot false-positive

    /// `HistorySessionsCard`'s own, unrelated `isWide: Bool` property (a different
    /// symbol that happens to share a word) would false-positive on a bare "isWide"
    /// scan, so this checks the qualified call form and the declaration's own
    /// signature instead.
    func testSessionListRuleIsWideAndMinimumWideWidthAreGone() throws {
        let repo = try Self.repoRoot()
        XCTAssertEqual(try matchCount("SessionListRule.isWide", in: repo), 0)
        XCTAssertEqual(try matchCount("SessionListRule.minimumWideWidth", in: repo), 0)
        XCTAssertEqual(try matchCount("static func isWide(availableWidth", in: repo), 0)
        XCTAssertEqual(try matchCount("static let minimumWideWidth", in: repo), 0)
    }

    func testSessionCopyListHeaderAndListColumnsAreGone() throws {
        let repo = try Self.repoRoot()
        XCTAssertEqual(try matchCount("listHeader", in: repo), 0)
        XCTAssertEqual(try matchCount("listColumns", in: repo), 0)
    }

    func testAgentsSettingsTextHookStatusTintIsGone() throws {
        let repo = try Self.repoRoot()
        XCTAssertEqual(try matchCount("hookStatusTint", in: repo), 0)
    }

    /// `OverviewCopy.burnLine` (a different type) legitimately keeps the bare word
    /// "burnLine", so this checks the file the dead code lived in rather than banning
    /// the word tree-wide.
    func testOverviewViewNoLongerDeclaresBurnLine() throws {
        let source = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("UsageTracker/UI/Dashboard/OverviewView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("burnLine"), "OverviewView.burnLine must be gone")
    }

    // MARK: - Kept, as the contract requires

    func testOverviewCopyBurnLineStillExists() {
        XCTAssertEqual(
            OverviewCopy.burnLine(burn: nil, retained: false),
            "Burn rate: not enough data"
        )
    }

    func testSettingsViewUsageSummaryStillExists() {
        let service = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Session", percent: 42, kind: .session),
            Fixture.bucket(id: "seven_day", label: "Weekly", percent: 18, kind: .weekly),
        ])
        // `shortWindowName` maps `.session`/`.weekly` to fixed short names ("Session",
        // "Week"), ignoring the bucket's own `label` — the survivor is confirmed by
        // behaviour, not by the fixture's own label text.
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .used), "Session 42% · Week 18%")
    }

    func testSessionCopySubAgentsTitleStillExists() {
        XCTAssertEqual(SessionCopy.subAgentsTitle(count: 5), "Sub-agents (5)")
        XCTAssertEqual(SessionCopy.subAgentsTitle(count: 0), "Sub-agents (0)")
    }

    /// A survivor check for the three kept symbols, tree-wide: each must still be
    /// declared somewhere under the scanned directories, not merely callable from this
    /// one test target's own fixtures.
    func testTheThreeKeptSymbolsAreStillDeclaredInTheTree() throws {
        let repo = try Self.repoRoot()
        XCTAssertGreaterThan(try matchCount("static func burnLine", in: repo), 0, "OverviewCopy.burnLine must stay declared")
        XCTAssertGreaterThan(try matchCount("static func usageSummary", in: repo), 0, "SettingsView.usageSummary must stay declared")
        XCTAssertGreaterThan(try matchCount("static func subAgentsTitle", in: repo), 0, "SessionCopy.subAgentsTitle must stay declared")
    }
}
