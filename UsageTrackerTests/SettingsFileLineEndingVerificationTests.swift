import XCTest
@testable import Omelette

/// Tester's verification of `SettingsFile.writeText` (whole-branch review of 4.0, Codex C1, CRLF
/// too): a file that already ends in a line ending is written back ending in the same one, and
/// a file that does not gets one. "\r\n" is a single `Character`, so the fix looks at the last
/// byte; these tests go through the file, LF, CRLF, no final ending and mixed, and through the
/// one other writer of config.toml, `AgentHooksInstaller`.
final class SettingsFileLineEndingVerificationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsFileLineEndingVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var url: URL { root.appendingPathComponent("config.toml") }

    private func bytes() throws -> [UInt8] { Array(try Data(contentsOf: url)) }

    private func write(_ text: String) throws -> [UInt8] {
        try SettingsFile.writeText(SettingsFile.lines(of: text), to: url)
        return try bytes()
    }

    // MARK: - writeText

    func testAFileEndingInALineEndingComesBackByteForByte() throws {
        for text in [
            "a = 1\nb = 2\n",
            "a = 1\r\nb = 2\r\n",
            "a = 1\r\n\r\n",                // a blank last line
            "a = 1\n\n",
            "a = 1\r\nb = 2\n",             // mixed, LF last
            "a = 1\nb = 2\r\n",             // mixed, CRLF last
            "\r\n", "\n",
        ] {
            XCTAssertEqual(try write(text), Array(text.utf8), text.debugDescription)
        }
    }

    func testAFileWithNoFinalLineEndingGetsOneAndKeepsEverythingBeforeIt() throws {
        for text in ["a = 1\nb = 2", "a = 1\r\nb = 2", "a = 1\r\nb = 2\r"] {
            let written = try write(text)
            XCTAssertEqual(written.last, UInt8(ascii: "\n"), text.debugDescription)
            XCTAssertTrue(written.starts(with: Array(text.utf8)), "nothing before the end changes: \(text.debugDescription)")
            XCTAssertLessThanOrEqual(written.count, text.utf8.count + 2, "one line ending, not a blank line: \(text.debugDescription)")
            XCTAssertNotEqual(Array(written.suffix(2)), Array("\n\n".utf8), text.debugDescription)
            XCTAssertNotEqual(Array(written.suffix(4)), Array("\r\n\r\n".utf8), text.debugDescription)
        }
    }

    func testWritingWhatWasWrittenChangesNothing() throws {
        for text in ["a = 1\nb = 2", "a = 1\r\nb = 2", "a = 1\r\nb = 2\r\n", "a = 1\nb = 2\r\n", "x\r\n\r\ny"] {
            let once = try write(text)
            let twice = try write(String(decoding: once, as: UTF8.self))
            XCTAssertEqual(twice, once, text.debugDescription)
        }
    }

    func testNoLinesWriteOneLineEnding() throws {
        try SettingsFile.writeText([], to: url)
        XCTAssertEqual(try bytes(), [UInt8(ascii: "\n")])
        try SettingsFile.writeText([""], to: url)
        XCTAssertEqual(try bytes(), [UInt8(ascii: "\n")])
    }

    // MARK: - config.toml through AgentHooksInstaller

    private let hook = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook"
    private let notify = #"notify = ["/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook", "--codex"]"#

    func testRemovingOurNotifyLineFromACRLFConfigLeavesTheRestByteForByte() throws {
        let crlf = "model = \"gpt\"\r\n\(notify)\r\n\r\n[tui]\r\nx = 1\r\n"
        try Data(crlf.utf8).write(to: url)

        try AgentHooksInstaller.removeCodex(configURL: url, helperPath: hook)

        XCTAssertEqual(try bytes(), Array("model = \"gpt\"\r\n\r\n[tui]\r\nx = 1\r\n".utf8),
                       "no bare LF after the last CRLF")
    }

    func testRemovingOurNotifyLineFromAnLFConfigAndFromOneWithNoFinalEnding() throws {
        try Data("model = \"gpt\"\n\(notify)\n[tui]\nx = 1\n".utf8).write(to: url)
        try AgentHooksInstaller.removeCodex(configURL: url, helperPath: hook)
        XCTAssertEqual(try bytes(), Array("model = \"gpt\"\n[tui]\nx = 1\n".utf8))

        try Data("model = \"gpt\"\n\(notify)\n[tui]\nx = 1".utf8).write(to: url)
        try AgentHooksInstaller.removeCodex(configURL: url, helperPath: hook)
        XCTAssertEqual(try bytes(), Array("model = \"gpt\"\n[tui]\nx = 1\n".utf8))
    }

    func testInstallingIntoACRLFConfigKeepsItsLinesAndItsFinalCRLF() throws {
        let crlf = "model = \"gpt\"\r\n[tui]\r\nx = 1\r\n"
        try Data(crlf.utf8).write(to: url)

        try AgentHooksInstaller.installCodex(configURL: url, helperPath: hook)

        let text = String(decoding: try bytes(), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("[tui]\r\nx = 1\r\n"), text.debugDescription)
        XCTAssertTrue(text.hasPrefix("model = \"gpt\"\r\n"), text.debugDescription)
        XCTAssertFalse(text.hasSuffix("\n\n"), text.debugDescription)
        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: url, helperPath: hook), .installed)
    }

    func testInstallingOverAnOutdatedNotifyOfACRLFConfigEndsWithoutAStrayLineFeed() throws {
        let old = #"notify = ["/Users/other/Library/Application Support/UsageTracker/bin/omelette-hook", "--codex"]"#
        let crlf = "\(old)\r\nmodel = \"gpt\"\r\n"
        try Data(crlf.utf8).write(to: url)

        try AgentHooksInstaller.installCodex(configURL: url, helperPath: hook)

        let text = String(decoding: try bytes(), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("model = \"gpt\"\r\n"), text.debugDescription)
        XCTAssertFalse(text.hasSuffix("\n\n"), text.debugDescription)
        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: url, helperPath: hook), .installed)
    }
}
