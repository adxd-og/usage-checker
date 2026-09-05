import XCTest
@testable import Omelette

/// The history tab's empty state used to tell every user to "run a `claude`
/// session", including the ones looking at Grok. The command is the one thing in
/// that sentence that has to be right, so it is a function with a test.
final class CLICommandNameTests: XCTestCase {
    func testEachCostableProviderNamesItsOwnCommand() {
        XCTAssertEqual(DashboardState.cliCommandName(for: "claude"), "claude")
        XCTAssertEqual(DashboardState.cliCommandName(for: "codex"), "codex")
        XCTAssertEqual(DashboardState.cliCommandName(for: "grok"), "grok")
    }

    func testAnUnknownProviderFallsBackToClaude() {
        // The empty state is only ever shown for a provider with a cost log, so
        // an unknown id here means a new provider whose plumbing is half-landed.
        // Naming the commonest CLI beats naming none.
        XCTAssertEqual(DashboardState.cliCommandName(for: "gemini"), "claude")
        XCTAssertEqual(DashboardState.cliCommandName(for: ""), "claude")
    }
}
