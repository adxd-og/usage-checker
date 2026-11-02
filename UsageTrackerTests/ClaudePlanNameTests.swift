import XCTest
@testable import Omelette

/// The Claude plan's name: Claude Code's own `planDisplayName` from `~/.claude.json` when its
/// rate-limit tier is the polled credential's, `SubscriptionTier`'s mapping otherwise. "Apex"
/// stands for a name Anthropic gives a plan after this build: the mapping cannot produce it.
final class ClaudePlanNameTests: XCTestCase {
    private let ultra20x = "default_claude_max_20x"
    private let max5x = "default_claude_max_5x"

    private func account(_ name: String?, tier: String?) -> ClaudeCodeAccount {
        ClaudeCodeAccount(planDisplayName: name, organizationRateLimitTier: tier)
    }

    func testAMatchingTierTakesClaudeCodesName() {
        XCTAssertEqual(
            ClaudePlanName.plan(configAccount: account("Ultra", tier: ultra20x), subscriptionType: "max", rateLimitTier: ultra20x),
            "Claude Ultra"
        )
    }

    func testARenameAfterThisBuildShowsWhenTheTierMatches() {
        XCTAssertEqual(
            ClaudePlanName.plan(configAccount: account("Apex", tier: ultra20x), subscriptionType: "max", rateLimitTier: ultra20x),
            "Claude Apex"
        )
    }

    func testAnotherTierInTheFileFallsBackToTheMapping() {
        // Claude Code is signed into a 20x account, the app polls a 5x one.
        XCTAssertEqual(
            ClaudePlanName.plan(configAccount: account("Ultra", tier: ultra20x), subscriptionType: "max", rateLimitTier: max5x),
            "Claude Max"
        )
    }

    func testABlankOrMissingNameFallsBackToTheMapping() {
        for name in [nil, "", "  \n"] {
            XCTAssertEqual(
                ClaudePlanName.plan(configAccount: account(name, tier: max5x), subscriptionType: "max", rateLimitTier: max5x),
                "Claude Max",
                "\(String(describing: name))"
            )
        }
    }

    func testNoClaudeCodeAccountFallsBackToTheMapping() {
        XCTAssertEqual(
            ClaudePlanName.plan(configAccount: nil, subscriptionType: "max", rateLimitTier: ultra20x),
            "Claude Ultra"
        )
        XCTAssertEqual(ClaudePlanName.plan(configAccount: nil, subscriptionType: "pro", rateLimitTier: nil), "Claude Pro")
    }

    func testACredentialWithoutATierFallsBackToTheMapping() {
        for tier in [nil, "", " "] {
            XCTAssertEqual(
                ClaudePlanName.plan(configAccount: account("Apex", tier: ultra20x), subscriptionType: "max", rateLimitTier: tier),
                "Claude Max",
                "\(String(describing: tier))"
            )
        }
    }

    func testAFileWithoutATierFallsBackToTheMapping() {
        for tier in [nil, ""] {
            XCTAssertEqual(
                ClaudePlanName.plan(configAccount: account("Apex", tier: tier), subscriptionType: "max", rateLimitTier: ""),
                "Claude Max",
                "an absent tier on both sides is not a match"
            )
        }
    }

    func testANameThatAlreadySaysClaudeIsKeptAsIs() {
        XCTAssertEqual(
            ClaudePlanName.plan(configAccount: account("Claude Ultra", tier: ultra20x), subscriptionType: "max", rateLimitTier: ultra20x),
            "Claude Ultra"
        )
    }

    func testANameThatSaysClaudeInAnotherCaseIsKeptInItsOwnCase() {
        for name in ["CLAUDE ULTRA", "claude ultra"] {
            XCTAssertEqual(
                ClaudePlanName.plan(configAccount: account(name, tier: ultra20x), subscriptionType: "max", rateLimitTier: ultra20x),
                name
            )
        }
    }

    func testTeamAndEnterpriseKeepTheMappingsNameSoTheirSpendLimitStaysASpendLimit() {
        // `extraUsageTitle(plan:)` reads "Team" / "Enterprise" off the plan string.
        for (subscription, expected) in [("team", "Claude Team"), ("enterprise", "Claude Enterprise")] {
            let tier = "default_claude_\(subscription)"
            let plan = ClaudePlanName.plan(
                configAccount: account("Apex", tier: tier), subscriptionType: subscription, rateLimitTier: tier
            )
            XCTAssertEqual(plan, expected)
            XCTAssertEqual(extraUsageTitle(plan: plan), "Spend limit")
        }
    }

    func testTheTierMatchesAcrossCaseAndWhitespace() {
        XCTAssertEqual(
            ClaudePlanName.plan(
                configAccount: account(" Apex ", tier: " Default_Claude_Max_20x\n"),
                subscriptionType: "max",
                rateLimitTier: "DEFAULT_CLAUDE_MAX_20X"
            ),
            "Claude Apex"
        )
    }
}
