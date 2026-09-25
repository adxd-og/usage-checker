import XCTest
@testable import Omelette

/// Independent verification of P0 (liquid-glass redesign spec § Design → Platform
/// floor: "`scripts/update_appcast.sh` writes the floor"; § Facts: "the script
/// prepends the new item and leaves every existing item untouched"). The executor's
/// `UpdateAppcastScriptTests` exercises a two-item synthetic fixture; this file
/// instead runs the real `docs/appcast.xml` (16 items as of this branch) to check the
/// "several items" case against production data, and adds two edge cases the
/// executor's suite does not: a `project.yml` with no deployment-floor key at all
/// (not just a disagreement), and a disagreement in the opposite direction (a target
/// floor *above* the base, not just below it).
final class UpdateAppcastScriptVerificationTests: XCTestCase {
    private var directory: URL!
    private var feedURL: URL { directory.appendingPathComponent("docs/appcast.xml") }
    private var projectURL: URL { directory.appendingPathComponent("project.yml") }
    private var repo: URL!
    private var realFeed = ""

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        repo = try Self.repoRoot()
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("UpdateAppcastScriptVerificationTests-\(UUID().uuidString)", isDirectory: true)
        for folder in [
            "scripts",
            "docs",
            "build/DerivedData-release/SourcePackages/artifacts",
            "build/DerivedData/SourcePackages/artifacts/sparkle/bin",
        ] {
            try fileManager.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["scripts/update_appcast.sh", "project.yml", "CHANGELOG.md"] {
            try fileManager.copyItem(at: repo.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        // The real, production appcast feed: 16 items as of this branch, not a
        // two-item synthetic fixture.
        realFeed = try String(contentsOf: repo.appendingPathComponent("docs/appcast.xml"), encoding: .utf8)
        try realFeed.write(to: feedURL, atomically: true, encoding: .utf8)
        let signUpdate = directory.appendingPathComponent("build/DerivedData/SourcePackages/artifacts/sparkle/bin/sign_update")
        try "#!/bin/sh\necho 'sparkle:edSignature=\"FIXTURE==\" length=\"3\"'\n"
            .write(to: signUpdate, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signUpdate.path)
        try Data("dmg".utf8).write(to: directory.appendingPathComponent("build/Omelette.dmg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The real, several-item feed

    func testTheRealSixteenItemFeedKeepsEveryExistingItemByteIdenticalAndPrependsOnlyOne() throws {
        let itemsBefore = realFeed.components(separatedBy: "<item>").count - 1
        XCTAssertGreaterThan(itemsBefore, 10, "expected the real feed to carry several items, found \(itemsBefore)")

        let run = try runScript(version: "3.0.0-verify", build: "9001")
        XCTAssertEqual(run.status, 0, run.output)

        let after = try String(contentsOf: feedURL, encoding: .utf8)
        let itemsAfter = after.components(separatedBy: "<item>").count - 1
        XCTAssertEqual(itemsAfter, itemsBefore + 1, "exactly one item must be added to the real feed")

        // Everything that existed before must still be present byte for byte: the new
        // item is the only insertion, so removing exactly one "<item>...</item>" block
        // whose title is the new version from `after` must reproduce `realFeed` exactly.
        guard let inserted = Self.item("3.0.0-verify", in: after) else {
            return XCTFail("the new item was not found in the updated feed")
        }
        let withoutInsertion = after.replacingOccurrences(of: inserted, with: "")
        XCTAssertEqual(withoutInsertion, realFeed, "removing only the new item must reproduce the original feed exactly")
    }

    func testTheRealFeedsNewestExistingItemIsUnchangedAndNowSecond() throws {
        guard let firstTitle = Self.firstItemTitle(in: realFeed) else {
            return XCTFail("could not find any <title>Omelette v…</title> in the real feed")
        }
        let versionBefore = String(firstTitle.dropFirst("Omelette v".count))
        let beforeBlock = try XCTUnwrap(Self.item(versionBefore, in: realFeed))

        let run = try runScript(version: "3.0.0-verify", build: "9002")
        XCTAssertEqual(run.status, 0, run.output)
        let after = try String(contentsOf: feedURL, encoding: .utf8)

        XCTAssertEqual(Self.item(versionBefore, in: after), beforeBlock, "the item that was first before the update is untouched")
        // The new item must sit ahead of it: its <item> opening tag occurs earlier in the file.
        let newRange = try XCTUnwrap(after.range(of: "<title>Omelette v3.0.0-verify</title>"))
        let oldRange = try XCTUnwrap(after.range(of: "<title>Omelette v\(versionBefore)</title>"))
        XCTAssertLessThan(newRange.lowerBound, oldRange.lowerBound, "the new item must be prepended ahead of the previously-newest item")
    }

    func testTheNewItemOnTheRealFeedCarriesTheProjectsCurrentFloor() throws {
        let run = try runScript(version: "3.0.0-verify", build: "9003")
        XCTAssertEqual(run.status, 0, run.output)
        let after = try String(contentsOf: feedURL, encoding: .utf8)
        let item = try XCTUnwrap(Self.item("3.0.0-verify", in: after))
        XCTAssertTrue(item.contains("<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>"), item)
    }

    // MARK: - Edge cases the fixture-based suite does not cover

    /// Not a disagreement — nothing at all. Every `deploymentTarget`/`macOS`/
    /// `MACOSX_DEPLOYMENT_TARGET` key is renamed so the script's `sed` extraction
    /// matches zero lines. `FLOORS` is then empty, and `set -u` makes an unguarded
    /// empty-variable read a hard error; the script must fail its own explicit check
    /// ("found: none") rather than crash on the empty value it derives `MIN_SYSTEM` from.
    func testWhenProjectYamlNamesNoDeploymentFloorAtAllTheScriptFailsBeforeWritingAnything() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let mutated = project
            .replacingOccurrences(of: "deploymentTarget:", with: "deploymentTargetRenamed:")
            .replacingOccurrences(of: "macOS: \"26.0\"", with: "macOSRenamed: \"26.0\"")
            .replacingOccurrences(of: "MACOSX_DEPLOYMENT_TARGET:", with: "MACOSX_DEPLOYMENT_TARGET_RENAMED:")
        try mutated.write(to: projectURL, atomically: true, encoding: .utf8)

        let run = try runScript(version: "3.0.0-verify", build: "9004")

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("found: none"), run.output)
        XCTAssertEqual(try String(contentsOf: feedURL, encoding: .utf8), realFeed, "the feed is not written")
    }

    /// The executor's own `testFloorsThatDisagreeStopTheScriptBeforeItWritesAnything`
    /// only lowers one target's floor (26.0 → 15.0). This raises one instead (26.0 →
    /// 27.0), the opposite direction, to check the disagreement check is symmetric and
    /// not just a "found something less than the base" comparison.
    func testADisagreementWhereATargetFloorIsHigherThanTheBaseAlsoStopsTheScript() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        // "UsageTrackerWidget" also names a source path and a dependency earlier in the
        // file (project.yml:54, :73); only the two-space-indented top-level key at
        // project.yml:169 is the widget *target*'s own section.
        let widgetTargetHeader = try XCTUnwrap(project.range(of: "\n  UsageTrackerWidget:\n"))
        let widgetFloor = try XCTUnwrap(
            project.range(of: "deploymentTarget: \"26.0\"", range: widgetTargetHeader.upperBound..<project.endIndex)
        )
        try project.replacingCharacters(in: widgetFloor, with: "deploymentTarget: \"27.0\"")
            .write(to: projectURL, atomically: true, encoding: .utf8)

        let run = try runScript(version: "3.0.0-verify", build: "9005")

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("must carry one deployment floor"), run.output)
        XCTAssertEqual(try String(contentsOf: feedURL, encoding: .utf8), realFeed, "the feed is not written")
    }

    // MARK: - Helpers

    private struct Run {
        let status: Int32
        let output: String
    }

    private func runScript(version: String, build: String) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [directory.appendingPathComponent("scripts/update_appcast.sh").path, version, build]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private static func item(_ version: String, in feed: String) -> String? {
        guard let title = feed.range(of: "<title>Omelette v\(version)</title>"),
              let start = feed.range(of: "    <item>\n", options: .backwards, range: feed.startIndex..<title.lowerBound),
              let end = feed.range(of: "    </item>\n", range: title.upperBound..<feed.endIndex)
        else { return nil }
        return String(feed[start.lowerBound..<end.upperBound])
    }

    /// The `<title>` text of the first `<item>` in the feed (the current newest release).
    private static func firstItemTitle(in feed: String) -> String? {
        guard let itemStart = feed.range(of: "<item>"),
              let titleStart = feed.range(of: "<title>", range: itemStart.upperBound..<feed.endIndex),
              let titleEnd = feed.range(of: "</title>", range: titleStart.upperBound..<feed.endIndex)
        else { return nil }
        return String(feed[titleStart.upperBound..<titleEnd.lowerBound])
    }

    private static func repoRoot() throws -> URL {
        var candidate = Bundle(for: UpdateAppcastScriptVerificationTests.self).bundleURL
        for _ in 0..<25 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("scripts/update_appcast.sh").path) {
                return candidate
            }
        }
        throw XCTSkip("could not locate the repo root by walking up from the test bundle")
    }
}
