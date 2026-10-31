import XCTest
@testable import Omelette

/// Tester's verification of the status line under two names (plan 2026-10-31-brioche-rename,
/// R5, Review Focus 3): which commands are ours, what an old entry reads as under each link a
/// new setup might be handed, and what a write or a remove leaves of a file that is not ours.
final class StatusLineBriocheVerificationTests: XCTestCase {
    private var root: URL!
    private let home = "/Users/tester/Library/Application Support/UsageTracker/bin"
    private var cli: String { home + "/brioche" }
    private var oldCLI: String { home + "/omelette" }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineBriocheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    private func write(_ statusLine: [String: Any], extra: [String: Any] = ["theme": "dark"]) throws {
        var file = extra
        file["statusLine"] = statusLine
        try JSONSerialization.data(withJSONObject: file).write(to: settingsURL)
    }

    private func entry() throws -> [String: Any]? {
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        return file["statusLine"] as? [String: Any]
    }

    private func status(_ path: String? = nil) -> HookInstallStatus {
        StatusLineInstaller.status(settingsURL: settingsURL, cliPath: path ?? cli)
    }

    func testWhatIsOursIsDecidedByTheBinFolderAndTheSubcommand() {
        XCTAssertTrue(StatusLineInstaller.isOurs(StatusLineInstaller.command(cliPath: cli)))
        XCTAssertTrue(StatusLineInstaller.isOurs(StatusLineInstaller.command(cliPath: oldCLI)))
        XCTAssertTrue(StatusLineInstaller.isOurs("\(cli) statusline"), "unquoted, as typed by hand")
        XCTAssertFalse(StatusLineInstaller.isOurs("\(cli) mcp"), "the right link, the wrong subcommand")
        XCTAssertFalse(StatusLineInstaller.isOurs("\(oldCLI) status"))
        XCTAssertFalse(StatusLineInstaller.isOurs("/opt/homebrew/bin/brioche statusline"), "the package manager's tool")
        XCTAssertFalse(StatusLineInstaller.isOurs("/usr/local/bin/omelette statusline"))
        XCTAssertFalse(StatusLineInstaller.isOurs("/Users/tester/Library/Application Support/UsageTracker/brioche statusline"), "not in bin")
        XCTAssertFalse(StatusLineInstaller.isOurs("'\(home)/omelette-hook' --codex-hook"))
    }

    func testAnEntryUnderTheNewNameThatIsCompleteReadsAsInstalled() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: cli))

        XCTAssertEqual(status(), .installed)
    }

    func testAnEntryUnderTheNewNameFromAnotherHomeOffersAnUpdate() throws {
        try write(StatusLineInstaller.desiredEntry(
            commandPath: "/Users/other/Library/Application Support/UsageTracker/bin/brioche"
        ))

        XCTAssertEqual(status(), .outdated)
    }

    /// `usableCLILink` hands the installers bin/omelette when bin/brioche is another tool's: an
    /// entry that runs bin/brioche would then run that other tool, so it must offer an update.
    func testAnEntryRunningBriocheOffersAnUpdateOnceBriocheIsTaken() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: cli))

        XCTAssertEqual(status(oldCLI), .outdated)
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: oldCLI)
        XCTAssertEqual(status(oldCLI), .installed)
        XCTAssertEqual(try entry()?["command"] as? String, StatusLineInstaller.command(cliPath: oldCLI))
    }

    func testAnEntryRunningOmeletteIsInstalledWhenOmeletteIsWhatANewSetupGets() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: oldCLI))

        XCTAssertEqual(status(oldCLI), .installed)
    }

    func testAnOldEntryWithAForeignIntervalOffersAnUpdateAndTheUpdateSetsIt() throws {
        try write(["type": "command", "command": StatusLineInstaller.command(cliPath: oldCLI), "refreshInterval": 5])
        XCTAssertEqual(status(), .outdated)

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(try entry()?["refreshInterval"] as? Int, StatusLineInstaller.refreshInterval)
        XCTAssertEqual(status(), .installed)
    }

    func testASecondInstallChangesNothing() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: oldCLI))
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)
        let first = try Data(contentsOf: settingsURL)

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(try Data(contentsOf: settingsURL), first)
    }

    func testAnotherToolsOmeletteIsAConflictAndNeitherInstallNorRemoveTouchesIt() throws {
        let theirs = "/usr/local/bin/omelette statusline"
        try write(["type": "command", "command": theirs])
        let before = try Data(contentsOf: settingsURL)

        XCTAssertEqual(status(), .conflict(theirs))
        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli))
        try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
    }

    func testRemoveLeavesAForeignBriocheStatusLineAlone() throws {
        let theirs = "/opt/homebrew/bin/brioche statusline"
        try write(["type": "command", "command": theirs])
        let before = try Data(contentsOf: settingsURL)

        try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
    }

    func testRemoveTakesAnEntryUnderEitherNameFromAnyHome() throws {
        for command in [
            StatusLineInstaller.command(cliPath: cli),
            StatusLineInstaller.command(cliPath: "/Users/other/Library/Application Support/UsageTracker/bin/omelette"),
        ] {
            try write(["type": "command", "command": command])

            try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli)

            XCTAssertNil(try entry(), command)
            XCTAssertEqual(status(), .notInstalled)
        }
    }

    func testTheWriterKeepsEveryOtherKeyOfTheFile() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: oldCLI), extra: ["theme": "dark", "env": ["A": "1"]])

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(file["theme"] as? String, "dark")
        XCTAssertEqual((file["env"] as? [String: String])?["A"], "1")
    }
}
