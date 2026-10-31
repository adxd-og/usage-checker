import XCTest
@testable import Omelette

/// The rename (plan 2026-10-31-brioche-rename, R5): a status line written before it says
/// `bin/omelette`. It keeps working, it is still ours, and a write moves it to the new name.
final class StatusLineBriocheNameTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/brioche"
    private let oldCLI = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineBriocheNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    private func write(_ statusLine: [String: Any]) throws {
        let file: [String: Any] = ["model": "opus", "statusLine": statusLine]
        try JSONSerialization.data(withJSONObject: file).write(to: settingsURL)
    }

    private func written() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    private var status: HookInstallStatus {
        StatusLineInstaller.status(settingsURL: settingsURL, cliPath: cli)
    }

    func testTheOldNameIsTheSameFolderWithTheOtherName() {
        XCTAssertEqual(AgentPaths.legacyCLIName, "omelette")
        XCTAssertEqual(AgentPaths.legacyCLIPath(for: cli), oldCLI)
        XCTAssertEqual(AgentPaths.legacyCLIPath(for: oldCLI), oldCLI)
    }

    func testACommandUnderEitherNameIsOurs() {
        XCTAssertTrue(StatusLineInstaller.isOurs(StatusLineInstaller.command(cliPath: cli)))
        XCTAssertTrue(StatusLineInstaller.isOurs(StatusLineInstaller.command(cliPath: oldCLI)))
    }

    func testAHookCommandIsStillNeverOurs() {
        let hook = "'/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook'"
        XCTAssertFalse(StatusLineInstaller.isOurs(hook))
        XCTAssertFalse(StatusLineInstaller.isOurs(hook + " --codex-hook"))
    }

    func testACompleteEntryUnderTheOldNameReadsAsInstalled() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: oldCLI))

        XCTAssertEqual(status, .installed, "it works; an update asks nothing of the user")
    }

    func testAnOldNameEntryWithoutTheIntervalOffersAnUpdate() throws {
        try write(["type": "command", "command": StatusLineInstaller.command(cliPath: oldCLI)])

        XCTAssertEqual(status, .outdated)
    }

    func testAnOldNameEntryFromAnotherHomeOffersAnUpdate() throws {
        try write(StatusLineInstaller.desiredEntry(
            commandPath: "/Users/other/Library/Application Support/UsageTracker/bin/omelette"
        ))

        XCTAssertEqual(status, .outdated)
    }

    func testAWriteMovesAnOldNameEntryToTheNewNameAndKeepsTheRestOfTheFile() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: oldCLI))

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let file = try written()
        XCTAssertEqual(file["model"] as? String, "opus")
        let entry = try XCTUnwrap(file["statusLine"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, StatusLineInstaller.command(cliPath: cli))
        XCTAssertEqual(status, .installed)
    }

    func testRemoveTakesAnEntryUnderTheOldName() throws {
        try write(StatusLineInstaller.desiredEntry(commandPath: oldCLI))

        try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli)

        XCTAssertNil(try written()["statusLine"])
        XCTAssertEqual(status, .notInstalled)
    }

    func testAnotherToolsBriocheIsAConflict() throws {
        let theirs = "/opt/homebrew/bin/brioche statusline"
        try write(["type": "command", "command": theirs])

        XCTAssertEqual(status, .conflict(theirs))
        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli))
    }
}
