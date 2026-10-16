import XCTest
@testable import Omelette

/// The Chats / Projects choice kept per provider in one string: limit-analytics spec
/// (2026-10-16) § The tab, item 3 (the switch) and item 5 ("remembered per provider").
final class LimitsGroupingVerificationTests: XCTestCase {
    func testMalformedStoredStringsReadAsChats() {
        let malformed = [
            "", ",", ",,", "=", "claude", "claude=", "=projects", "claude=Projects", "claude=PROJECTS",
            "claude=projects=chats", "claude==projects", "claude:projects", " claude=projects", "claude =projects",
            "claude=projects ", "claude=timeline", "projects", "claude;codex",
        ]
        for stored in malformed {
            XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: stored), .chats, "stored \"\(stored)\"")
        }
    }

    func testAReadablePairSurvivesMalformedNeighbours() {
        let stored = "junk,=,claude=projects,codex=,=chats,,grok=chats=x"
        XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: stored), .projects)
        XCTAssertEqual(LimitsRules.grouping(for: "codex", stored: stored), .chats)
        XCTAssertEqual(LimitsRules.grouping(for: "grok", stored: stored), .chats)
    }

    func testStoringRewritesTheStringCleanAndInIDOrder() {
        XCTAssertEqual(
            LimitsRules.storing(.projects, for: "claude", in: "junk,codex=projects,claude=chats,="),
            "claude=projects,codex=projects"
        )
        XCTAssertEqual(LimitsRules.storing(.chats, for: "codex", in: "claude=projects"), "claude=projects,codex=chats")
        XCTAssertEqual(LimitsRules.storing(.projects, for: "claude", in: ",,"), "claude=projects")
    }

    func testStoringTheSameChoiceTwiceChangesNothing() {
        let once = LimitsRules.storing(.projects, for: "claude", in: "codex=projects")
        XCTAssertEqual(LimitsRules.storing(.projects, for: "claude", in: once), once)
    }

    func testEveryProviderRoundTripsAndNeverMovesAnother() {
        let ids = ["antigravity", "claude", "codex", "grok"]
        var stored = ""
        for (index, id) in ids.enumerated() {
            let choice: LimitsGrouping = index.isMultiple(of: 2) ? .projects : .chats
            stored = LimitsRules.storing(choice, for: id, in: stored)
        }
        XCTAssertEqual(stored, "antigravity=projects,claude=chats,codex=projects,grok=chats")
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(
                LimitsRules.grouping(for: id, stored: stored), index.isMultiple(of: 2) ? .projects : .chats, id
            )
        }
    }

    func testAChoiceForOneProviderLeavesAnUnreadableValueOfAnotherAsChats() {
        let stored = LimitsRules.storing(.projects, for: "codex", in: "claude=timeline")
        XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: stored), .chats)
        XCTAssertEqual(LimitsRules.grouping(for: "codex", stored: stored), .projects)
    }
}
