import XCTest
@testable import Omelette

/// The soft prompt is the one place Omelette asks to write to a file it does not
/// own, so the rule that decides whether to ask is a pure function with the whole
/// truth table pinned down.
final class AgentHooksPromptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHooksPromptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var projectsURL: URL { root.appendingPathComponent("projects", isDirectory: true) }
    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    // MARK: - shouldShow

    /// 2 × 4 × 2: exactly one cell prompts. `outdated` is deliberately not one of
    /// them — hooks are already there, and the Agents tab handles the update.
    func testOnlyAMissingInstallOnAMachineThatUsesClaudeEverPrompts() {
        let statuses: [HookInstallStatus] = [
            .installed, .outdated, .notInstalled, .conflict(AgentHooksInstaller.unparsableReason),
        ]
        for present in [true, false] {
            for status in statuses {
                for dismissed in [true, false] {
                    let expected = present && status == .notInstalled && !dismissed
                    XCTAssertEqual(
                        AgentHooksPrompt.shouldShow(claudePresent: present, status: status, dismissed: dismissed),
                        expected,
                        "claudePresent: \(present), status: \(status), dismissed: \(dismissed)"
                    )
                }
            }
        }
    }

    func testTheOneCellThatPrompts() {
        XCTAssertTrue(AgentHooksPrompt.shouldShow(claudePresent: true, status: .notInstalled, dismissed: false))
    }

    func testDismissingIsFinal() {
        XCTAssertFalse(AgentHooksPrompt.shouldShow(claudePresent: true, status: .notInstalled, dismissed: true))
    }

    /// Nothing to gain: a machine that has never run Claude Code gets no prompt,
    /// however cleanly the hooks would install.
    func testAMachineWithoutClaudeCodeIsNeverAsked() {
        XCTAssertFalse(AgentHooksPrompt.shouldShow(claudePresent: false, status: .notInstalled, dismissed: false))
    }

    // MARK: - claudeIsPresent

    func testClaudeIsAbsentWhenNeitherPathExists() {
        XCTAssertFalse(AgentHooksPrompt.claudeIsPresent(projectsURL: projectsURL, settingsURL: settingsURL))
    }

    func testTheProjectsDirectoryIsEnough() throws {
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        XCTAssertTrue(AgentHooksPrompt.claudeIsPresent(projectsURL: projectsURL, settingsURL: settingsURL))
    }

    /// Someone who keeps a settings.json but has never let Claude Code write a
    /// project transcript still counts as a user of it.
    func testTheSettingsFileAloneIsEnough() throws {
        try Data("{}".utf8).write(to: settingsURL)
        XCTAssertTrue(AgentHooksPrompt.claudeIsPresent(projectsURL: projectsURL, settingsURL: settingsURL))
    }
}
