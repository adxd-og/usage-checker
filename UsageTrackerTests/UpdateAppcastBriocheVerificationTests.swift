import XCTest
@testable import Omelette

/// Tester's verification of the release the rename opens (plan 2026-10-31-brioche-rename, Task 8
/// and R8): `update_appcast.sh` run on a copy of the REAL CHANGELOG, project.yml and feed, for
/// the 4.0.0 section that is still headed "Unreleased". The existing script tests use a fixture
/// feed and a version that CHANGELOG already dated, so they cannot see this section.
final class UpdateAppcastBriocheVerificationTests: XCTestCase {
    private var directory: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        repo = try Self.repoRoot()
        let fm = FileManager.default
        directory = fm.temporaryDirectory
            .appendingPathComponent("UpdateAppcastBriocheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        for folder in [
            "scripts", "docs",
            "build/DerivedData-release/SourcePackages/artifacts",
            "build/DerivedData/SourcePackages/artifacts/sparkle/bin",
        ] {
            try fm.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["scripts/update_appcast.sh", "project.yml", "CHANGELOG.md", "docs/appcast.xml"] {
            try fm.copyItem(at: repo.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        // 4.0.0 is published now: the copy goes back to the feed it was released into.
        let feed = directory.appendingPathComponent("docs/appcast.xml")
        var xml = try String(contentsOf: feed, encoding: .utf8)
        if let title = xml.range(of: "<title>Brioche v4.0.0</title>"),
           let start = xml.range(of: "    <item>\n", options: .backwards, range: xml.startIndex..<title.lowerBound),
           let end = xml.range(of: "    </item>\n", range: title.upperBound..<xml.endIndex) {
            xml.removeSubrange(start.lowerBound..<end.upperBound)
            try xml.write(to: feed, atomically: true, encoding: .utf8)
        }
        let signUpdate = directory.appendingPathComponent("build/DerivedData/SourcePackages/artifacts/sparkle/bin/sign_update")
        try "#!/bin/sh\necho 'sparkle:edSignature=\"FIXTURE==\" length=\"3\"'\n"
            .write(to: signUpdate, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signUpdate.path)
        try Data("dmg".utf8).write(to: directory.appendingPathComponent("build/Brioche.dmg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var feedURL: URL { directory.appendingPathComponent("docs/appcast.xml") }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [directory.appendingPathComponent("scripts/update_appcast.sh").path] + arguments
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
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testTheUnreleased400SectionBecomesTheNotesOfABriocheItemAheadOfEveryOlderOne() throws {
        let before = try String(contentsOf: feedURL, encoding: .utf8)

        let result = try run(["4.0.0", "56"])

        XCTAssertEqual(result.status, 0, result.output)
        let after = try String(contentsOf: feedURL, encoding: .utf8)
        let titleRange = try XCTUnwrap(after.range(of: "<title>Brioche v4.0.0</title>"), "no new item")
        let firstItem = try XCTUnwrap(after.range(of: "    <item>\n"))
        XCTAssertLessThan(firstItem.lowerBound, titleRange.lowerBound)
        XCTAssertFalse(after[after.startIndex..<firstItem.lowerBound].contains("Brioche v4.0.0"), "the new item must be the first")
        let end = try XCTUnwrap(after.range(of: "    </item>\n", range: titleRange.upperBound..<after.endIndex))
        let item = String(after[titleRange.lowerBound..<end.upperBound])
        XCTAssertTrue(item.contains("releases/download/v4.0.0/Brioche.dmg"), item)
        XCTAssertTrue(item.contains("<sparkle:version>56</sparkle:version>"), item)
        XCTAssertTrue(item.contains("<h3>Name</h3>"), "the section's heading becomes the notes' heading: \(item)")
        XCTAssertTrue(item.contains("Omelette is now Brioche."), item)
        XCTAssertTrue(item.contains("<code>Omelette.app</code>"), item)
        XCTAssertFalse(item.contains("Unreleased"), "the heading's date text is not part of the notes: \(item)")
        XCTAssertFalse(item.contains("3.3.0"), "the section stops at the next version: \(item)")

        // Everything that was in the feed is still there, in order, byte for byte.
        let newItem = try XCTUnwrap(after.range(of: "    <item>\n"))
        var rest = after
        rest.removeSubrange(newItem.lowerBound..<end.upperBound)
        XCTAssertEqual(rest, before)
    }

    func testTheOlderItemsStillPointAtTheirOmeletteDMGs() throws {
        _ = try run(["4.0.0", "56"])

        let after = try String(contentsOf: feedURL, encoding: .utf8)
        XCTAssertTrue(after.contains("/Omelette.dmg\""), "published assets keep their names")
        XCTAssertEqual(after.components(separatedBy: "/Brioche.dmg\"").count - 1, 1, "only the new item names the new DMG")
    }

    func testTheFloorOfTheNewItemIsTheOneInProjectYML() throws {
        _ = try run(["4.0.0", "56"])

        let after = try String(contentsOf: feedURL, encoding: .utf8)
        let yml = try String(contentsOf: directory.appendingPathComponent("project.yml"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"macOS: "([0-9.]+)""#)
        let match = try XCTUnwrap(regex.firstMatch(in: yml, range: NSRange(yml.startIndex..., in: yml)))
        let floor = String(yml[try XCTUnwrap(Range(match.range(at: 1), in: yml))])
        XCTAssertTrue(after.contains("<sparkle:minimumSystemVersion>\(floor)</sparkle:minimumSystemVersion>"))
    }

    func testReleasingTheSameVersionTwiceIsRefused() throws {
        XCTAssertEqual(try run(["4.0.0", "56"]).status, 0)
        let once = try Data(contentsOf: feedURL)

        let again = try run(["4.0.0", "56"])

        XCTAssertNotEqual(again.status, 0)
        XCTAssertEqual(try Data(contentsOf: feedURL), once, "a refused run changes nothing")
    }

    private static func repoRoot() throws -> URL {
        var candidate = Bundle(for: UpdateAppcastBriocheVerificationTests.self).bundleURL
        for _ in 0..<25 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("scripts/update_appcast.sh").path) {
                return candidate
            }
        }
        XCTFail("scripts/update_appcast.sh not found above the test bundle")
        throw CocoaError(.fileNoSuchFile)
    }
}
