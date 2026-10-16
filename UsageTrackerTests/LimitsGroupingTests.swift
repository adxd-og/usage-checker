import XCTest
@testable import Omelette

/// Chats or Projects: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The
/// tab, item 3 ("a Chats / Projects switch") and item 5 ("The Chats / Projects choice is
/// remembered per provider"). A project's share is the sum of its chats (§ Design, Known
/// limitation). Project rows are cut and formatted like chat rows, and named by the
/// provider's decoder, which these tests replace with a pure lookup.
final class LimitsGroupingTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private var week: LimitWindow { LimitWindow(start: now.addingTimeInterval(-5 * day), end: now) }

    /// Stands in for the provider's decoder: a lookup, no disk.
    private func decoded(_ providerID: String, _ slug: String) -> String {
        ["-Users-tester-Projects-alpha": "alpha", "-Users-tester-Projects-beta": "beta"][slug] ?? slug
    }

    func testTheListOpensOnChats() {
        XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: ""), .chats)
    }

    func testTheChoiceIsRememberedPerProvider() {
        let claudeOnProjects = LimitsRules.storing(.projects, for: "claude", in: "")
        XCTAssertEqual(claudeOnProjects, "claude=projects")
        XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: claudeOnProjects), .projects)
        XCTAssertEqual(LimitsRules.grouping(for: "codex", stored: claudeOnProjects), .chats)
        let both = LimitsRules.storing(.chats, for: "codex", in: claudeOnProjects)
        XCTAssertEqual(both, "claude=projects,codex=chats")
        XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: both), .projects)
        XCTAssertEqual(LimitsRules.storing(.chats, for: "claude", in: both), "claude=chats,codex=chats")
    }

    func testAnUnreadableStoredValueReadsAsChatsAndIsDropped() {
        XCTAssertEqual(LimitsRules.grouping(for: "claude", stored: "claude=timeline"), .chats)
        XCTAssertEqual(LimitsRules.storing(.projects, for: "codex", in: "claude=timeline,junk"), "codex=projects")
    }

    func testAProjectRowCarriesItsNameChatCountShareAndDollars() {
        let share = Fixture.limitShare(window: week, chats: [
            Fixture.chatShare(id: "chat-a", title: "A", points: 3, cost: 186, lastAt: now),
            Fixture.chatShare(id: "chat-b", title: "B", points: 1.2, cost: 74, lastAt: now),
            Fixture.chatShare(id: "chat-c", title: "C", project: "-Users-tester-Projects-beta",
                              points: 0.5, cost: 31, lastAt: now),
        ])
        XCTAssertEqual(LimitsRules.projectRows(of: share, serviceID: "claude", showsAll: false, projectName: decoded),
                       LimitsRankedRows(rows: [
                           LimitsRow(
                               id: "-Users-tester-Projects-alpha", title: "alpha",
                               subtitle: "2 chats", share: "≈ 4.2 %", dollars: "$260"
                           ),
                           LimitsRow(
                               id: "-Users-tester-Projects-beta", title: "beta",
                               subtitle: "1 chat", share: "≈ 0.5 %", dollars: "$31"
                           ),
                       ], total: 2))
    }

    func testTheRowsFollowTheGrouping() {
        let share = Fixture.limitShare(
            window: week,
            chats: [Fixture.chatShare(id: "chat-a", title: "A", points: 3, cost: 186, lastAt: now)]
        )
        XCTAssertEqual(
            LimitsRules.rows(of: share, grouping: .chats, serviceID: "claude", showsAll: false, projectName: decoded),
            LimitsRules.chatRows(of: share, serviceID: "claude", showsAll: false, projectName: decoded)
        )
        XCTAssertEqual(
            LimitsRules.rows(of: share, grouping: .projects, serviceID: "claude", showsAll: false, projectName: decoded),
            LimitsRules.projectRows(of: share, serviceID: "claude", showsAll: false, projectName: decoded)
        )
    }

    func testTheSwitchReadsChatsThenProjects() {
        XCTAssertEqual(LimitsGrouping.allCases.map(LimitsCopy.groupingName), ["Chats", "Projects"])
        XCTAssertEqual(LimitsCopy.groupingPickerLabel, "Group by")
        XCTAssertEqual(LimitsRules.groupingKey, "limitsGrouping")
    }
}
