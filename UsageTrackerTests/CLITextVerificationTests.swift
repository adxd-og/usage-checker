import XCTest
@testable import Omelette

/// Independent verification of `CLIText`'s API-equivalent labelling, derived from
/// `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)": "a CLICore constant for the short suffix". Focus: the exact
/// wording, that `CostCopy` shares the identical value rather than a second copy the
/// two could drift apart, and that `--help` explains both marks it introduces.
final class CLITextVerificationTests: XCTestCase {
    func testTheSuffixIsExactlyParenthesizedAPIEquivalent() {
        XCTAssertEqual(CLIText.apiEquivalentSuffix, "(API-equivalent)")
    }

    /// `CostCopy.apiEquivalentSuffix` (the app side) is documented as reusing this
    /// constant rather than duplicating the string, so `omelette status` and the
    /// app's notification body cannot say it two different ways.
    func testTheAppSharesTheSameConstantRatherThanACopy() {
        XCTAssertEqual(CostCopy.apiEquivalentSuffix, CLIText.apiEquivalentSuffix)
    }

    /// `--help` is the only place a `≈` on the status line, or "(API-equivalent)" on
    /// `status`, is ever explained — both marks have to appear together.
    func testHelpTextExplainsBothTheLongSuffixAndTheShortMarker() {
        XCTAssertTrue(CLIText.usage.contains(CLIText.apiEquivalentSuffix), CLIText.usage)
        XCTAssertTrue(CLIText.usage.contains(StatusLineText.apiEquivalentMarker), CLIText.usage)
        XCTAssertTrue(
            CLIText.usage.localizedCaseInsensitiveContains("API list price")
                || CLIText.usage.localizedCaseInsensitiveContains("list prices"),
            "the help text has to say what the dollars actually are, not just show the marks"
        )
    }
}
