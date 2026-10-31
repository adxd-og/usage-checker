import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 "an ear open goes to the ear's subject", § 3.6: every open
/// starts at home except an ear's, which lands on its subject, even one that turns a close around.
final class IslandNavigationEarTests: XCTestCase {
    private let four = ["claude", "codex", "antigravity", "grok"]

    func testAnOpenFromClosedGoesToTheSubjectOrHome() {
        XCTAssertEqual(IslandNavigation.openInput(route: .fresh, subject: nil, reveal: nil), .open(subject: nil))
        XCTAssertEqual(IslandNavigation.openInput(route: .fresh, subject: "codex", reveal: nil), .open(subject: "codex"))
        XCTAssertEqual(IslandNavigation.openInput(route: .moveAndOpen, subject: "codex", reveal: nil), .open(subject: "codex"))
    }

    func testATurnedAroundCloseKeepsItsPageUnlessAnEarNamesASubject() {
        XCTAssertNil(IslandNavigation.openInput(route: .reverse, subject: nil, reveal: nil))
        XCTAssertEqual(IslandNavigation.openInput(route: .reverse, subject: "codex", reveal: nil), .open(subject: "codex"))
    }

    /// Codex's plan review 2: Grok's page has no agents card, so an ear about the agents goes home.
    func testAnOpenAskingForACardReachesHomeEvenWhenItTurnsACloseAround() throws {
        let input = try XCTUnwrap(IslandNavigation.openInput(route: .reverse, subject: nil, reveal: .agents))
        XCTAssertEqual(input, .open(subject: nil))
        XCTAssertEqual(IslandNavigation.reduce(.provider("grok"), input, providers: four).page, .all)
    }

    func testASubjectThatIsGoneLandsAtHome() {
        XCTAssertEqual(IslandNavigation.reduce(.all, .open(subject: "gemini"), providers: four).page, .all)
        XCTAssertEqual(IslandNavigation.reduce(.all, .open(subject: "codex"), providers: four).page, .provider("codex"))
    }
}
