import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Platform floor: "the 3.0 appcast item carries
/// `sparkle:minimumSystemVersion` 26.0, and the 2.7.1 item stays in the feed so Sparkle
/// keeps older systems on it. `scripts/update_appcast.sh` writes the floor." Each test
/// copies the real script, project.yml and CHANGELOG.md into its own temp directory and
/// runs it against a two-item fixture feed, a fake `sign_update` and a dummy DMG. It
/// never touches docs/appcast.xml, the keychain or the network.
final class UpdateAppcastScriptTests: XCTestCase {
    private var directory: URL!

    private var feedURL: URL { directory.appendingPathComponent("docs/appcast.xml") }
    private var projectURL: URL { directory.appendingPathComponent("project.yml") }

    /// Two items shaped like docs/appcast.xml: 2.7.1 (build 49) and 2.7.0 (build 48),
    /// both for macOS 14.0.
    static let fixtureFeed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Omelette</title>
        <link>https://adxd-og.github.io/usage-checker/appcast.xml</link>
        <description>Omelette release feed</description>
        <language>en</language>
        <item>
          <title>Omelette v2.7.1</title>
          <pubDate>Fri, 25 Sep 2026 02:17:48 +0300</pubDate>
          <sparkle:version>49</sparkle:version>
          <sparkle:shortVersionString>2.7.1</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <description><![CDATA[
    <p>Fixture notes for 2.7.1.</p>
          ]]></description>
          <enclosure
            url="https://github.com/adxd-og/usage-checker/releases/download/v2.7.1/Omelette.dmg"
            type="application/octet-stream"
            sparkle:edSignature="FIXTURE271=="
            length="24475353"/>
        </item>
        <item>
          <title>Omelette v2.7.0</title>
          <pubDate>Thu, 24 Sep 2026 17:59:50 +0300</pubDate>
          <sparkle:version>48</sparkle:version>
          <sparkle:shortVersionString>2.7.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <description><![CDATA[
    <p>Fixture notes for 2.7.0.</p>
          ]]></description>
          <enclosure
            url="https://github.com/adxd-og/usage-checker/releases/download/v2.7.0/Omelette.dmg"
            type="application/octet-stream"
            sparkle:edSignature="FIXTURE270=="
            length="24000000"/>
        </item>
      </channel>
    </rss>

    """

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        let repo = try Self.repoRoot()
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("UpdateAppcastScriptTests-\(UUID().uuidString)", isDirectory: true)
        // Both artifact folders the script searches must exist: it runs `find` over the two
        // of them under `set -euo pipefail`, and a missing one makes `find` exit 1 and
        // aborts the script.
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
        try Self.fixtureFeed.write(to: feedURL, atomically: true, encoding: .utf8)
        let signUpdate = directory.appendingPathComponent("build/DerivedData/SourcePackages/artifacts/sparkle/bin/sign_update")
        try "#!/bin/sh\necho 'sparkle:edSignature=\"FIXTURE==\" length=\"3\"'\n"
            .write(to: signUpdate, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signUpdate.path)
        try Data("dmg".utf8).write(to: directory.appendingPathComponent("build/Omelette.dmg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Behaviour

    func testEveryExistingLineOfTheFeedIsKeptByteForByte() throws {
        let run = try runScript()

        XCTAssertEqual(run.status, 0, run.output)
        let before = Data(Self.fixtureFeed.utf8)
        let after = try Data(contentsOf: feedURL)
        let marker = try XCTUnwrap(Self.fixtureFeed.range(of: "<language>en</language>\n"))
        let head = Data(Self.fixtureFeed[..<marker.upperBound].utf8)
        let tail = Data(Self.fixtureFeed[marker.upperBound...].utf8)
        XCTAssertEqual(head.count + tail.count, before.count)
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertEqual(after.prefix(head.count), head, "everything up to <language> is untouched")
        XCTAssertEqual(after.suffix(tail.count), tail, "every existing item and the closing tags are untouched")
        let inserted = String(decoding: after.dropFirst(head.count).dropLast(tail.count), as: UTF8.self)
        XCTAssertTrue(inserted.hasPrefix("    <item>\n"), inserted)
        XCTAssertTrue(inserted.hasSuffix("    </item>\n"), inserted)
    }

    func testTheNewItemCarriesTheProjectsFloorOf26() throws {
        let run = try runScript()

        XCTAssertEqual(run.status, 0, run.output)
        let item = try XCTUnwrap(Self.item("3.0.0", in: try String(contentsOf: feedURL, encoding: .utf8)))
        XCTAssertTrue(item.contains("      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>\n"), item)
        XCTAssertTrue(item.contains("<sparkle:version>50</sparkle:version>"), item)
    }

    func testThe14Point0ItemForOlderMacsIsUnchanged() throws {
        let run = try runScript()

        XCTAssertEqual(run.status, 0, run.output)
        let before = try XCTUnwrap(Self.item("2.7.1", in: Self.fixtureFeed))
        XCTAssertTrue(before.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
        XCTAssertTrue(before.contains("<sparkle:version>49</sparkle:version>"))
        XCTAssertEqual(Self.item("2.7.1", in: try String(contentsOf: feedURL, encoding: .utf8)), before)
    }

    func testFloorsThatDisagreeStopTheScriptBeforeItWritesAnything() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let appFloor = try XCTUnwrap(project.range(of: "deploymentTarget: \"26.0\""))
        try project.replacingCharacters(in: appFloor, with: "deploymentTarget: \"15.0\"")
            .write(to: projectURL, atomically: true, encoding: .utf8)

        let run = try runScript()

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("must carry one deployment floor"), run.output)
        XCTAssertEqual(try Data(contentsOf: feedURL), Data(Self.fixtureFeed.utf8), "the feed is not written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: feedURL.path + ".tmp"))
    }

    func testTheFloorIsReadFromTheProjectNotRepeatedInTheScript() throws {
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        try project.replacingOccurrences(of: "\"26.0\"", with: "\"27.0\"")
            .write(to: projectURL, atomically: true, encoding: .utf8)

        let run = try runScript()

        XCTAssertEqual(run.status, 0, run.output)
        let item = try XCTUnwrap(Self.item("3.0.0", in: try String(contentsOf: feedURL, encoding: .utf8)))
        XCTAssertTrue(item.contains("<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>"), item)
    }

    // MARK: - Helpers

    private struct Run {
        let status: Int32
        let output: String
    }

    /// `update_appcast.sh 3.0.0 50`, run from the temp directory; stdout and stderr together.
    private func runScript() throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [directory.appendingPathComponent("scripts/update_appcast.sh").path, "3.0.0", "50"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drained before waiting: a `waitUntilExit` before a read is the classic pipe deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// The `<item>` block titled "Omelette v<version>", indentation and final newline included.
    private static func item(_ version: String, in feed: String) -> String? {
        guard let title = feed.range(of: "<title>Omelette v\(version)</title>"),
              let start = feed.range(of: "    <item>\n", options: .backwards, range: feed.startIndex..<title.lowerBound),
              let end = feed.range(of: "    </item>\n", range: title.upperBound..<feed.endIndex)
        else { return nil }
        return String(feed[start.lowerBound..<end.upperBound])
    }

    /// The test host's working directory is "/", so the repository (or worktree) is found
    /// by walking up from the test bundle, which is built under its `build/DerivedData`.
    /// This is the approach of `StatusLineRefreshVerificationTests.findRepoRoot`, but it fails
    /// rather than skips.
    private static func repoRoot() throws -> URL {
        var candidate = Bundle(for: UpdateAppcastScriptTests.self).bundleURL
        for _ in 0..<25 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("scripts/update_appcast.sh").path) {
                return candidate
            }
        }
        XCTFail("scripts/update_appcast.sh not found above the test bundle")
        throw RepoRootNotFound()
    }
}

private struct RepoRootNotFound: Error {}
