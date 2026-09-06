import XCTest
@testable import Omelette

/// Every spelling the tool answers to. Parsing is pure, so the whole surface is here
/// rather than in a shell script nobody runs.
final class CLICommandTests: XCTestCase {
    func testNoArgumentsPrintsTheUsageText() {
        XCTAssertEqual(CLICommand.parse([]), .help)
    }

    func testHelpAndVersionHaveTheThreeSpellingsPeopleTry() {
        for argument in ["help", "--help", "-h"] {
            XCTAssertEqual(CLICommand.parse([argument]), .help, argument)
        }
        for argument in ["version", "--version", "-v"] {
            XCTAssertEqual(CLICommand.parse([argument]), .version, argument)
        }
    }

    func testStatusAndItsOneOption() {
        XCTAssertEqual(CLICommand.parse(["status"]), .status(json: false))
        XCTAssertEqual(CLICommand.parse(["status", "--json"]), .status(json: true))
    }

    func testStatusLineDefaultsToClaudeAndTakesAProvider() {
        XCTAssertEqual(CLICommand.parse(["statusline"]), .statusLine(provider: "claude"))
        XCTAssertEqual(CLICommand.parse(["statusline", "--provider", "codex"]), .statusLine(provider: "codex"))
    }

    func testAProviderFlagWithNothingAfterItIsAUsageError() {
        XCTAssertEqual(
            CLICommand.parse(["statusline", "--provider"]),
            .usageError("`--provider` needs a provider id, for example `--provider codex`")
        )
        XCTAssertEqual(
            CLICommand.parse(["statusline", "--provider", "--json"]),
            .usageError("`--provider` needs a provider id, for example `--provider codex`")
        )
    }

    func testMCPTakesNothing() {
        XCTAssertEqual(CLICommand.parse(["mcp"]), .mcp)
        XCTAssertEqual(CLICommand.parse(["mcp", "--port", "80"]), .usageError("`mcp` takes no options: --port"))
    }

    func testAnUnknownCommandOrOptionSaysWhichOne() {
        XCTAssertEqual(CLICommand.parse(["stats"]), .usageError("Unknown command: stats"))
        XCTAssertEqual(CLICommand.parse(["status", "--verbose"]), .usageError("Unknown option for `status`: --verbose"))
        XCTAssertEqual(CLICommand.parse(["statusline", "-p", "codex"]), .usageError("Unknown option for `statusline`: -p"))
    }

    func testTheUsageTextNamesEveryCommand() {
        for command in ["status", "statusline", "mcp", "--version", "--help"] {
            XCTAssertTrue(CLIText.usage.contains(command), "usage text forgot \(command)")
        }
        XCTAssertTrue(CLIText.usage.contains("status.json"))
    }

    func testTheExitCodesAreTheOnesDocumented() {
        XCTAssertEqual(CLIText.noDataExitCode, 2)
        XCTAssertEqual(CLIText.usageExitCode, 64, "EX_USAGE from sysexits(3)")
    }
}
