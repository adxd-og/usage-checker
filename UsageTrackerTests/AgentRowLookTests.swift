import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Components, "Agent row: provider logo with a status dot
/// at the bottom-right", § Principles 2 ("the only filled control is the primary
/// action (Allow)") and 3 (no uppercase headings: each row says its state).
/// `Main.dc.html`, `Popover-Claude.dc.html`.
final class AgentRowLookTests: XCTestCase {
    func testOnlyNeedsYouIsSaidOnTheTitleLine() {
        XCTAssertEqual(AgentRowText.titleBadge(.needsYou), "Needs you")
        XCTAssertNil(AgentRowText.titleBadge(.working))
        XCTAssertNil(AgentRowText.titleBadge(.done))
        XCTAssertNil(AgentRowText.titleBadge(.idle))
    }

    func testOnTheAllTabTheSecondLineIsWhatTheAgentIsDoing() {
        let waiting = Fixture.agentSession(state: .needsYou, activity: "Which option do you prefer?")
        XCTAssertEqual(AgentRowText.rowSubtitle(for: waiting, providerTab: false), "Which option do you prefer?")
        XCTAssertEqual(AgentRowText.rowSubtitle(for: Fixture.agentSession(state: .working), providerTab: false), "Working")
    }

    func testOnAProviderTabTheSecondLineSaysTheStateUnlessTheTitleDoes() {
        let done = Fixture.agentSession(state: .done, activity: "Probe whether screen capture works from the helper")
        XCTAssertEqual(AgentRowText.rowSubtitle(for: done, providerTab: true),
                       "Done · Probe whether screen capture works from the helper")
        let waiting = Fixture.agentSession(state: .needsYou, activity: "Which option do you prefer?")
        XCTAssertEqual(AgentRowText.rowSubtitle(for: waiting, providerTab: true), "Which option do you prefer?")
    }

    func testTheDotIsYolkBlueGreenOrMuted() {
        XCTAssertEqual(AgentRowText.dotToken(.needsYou), .accent)
        XCTAssertEqual(AgentRowText.dotToken(.working), .working)
        XCTAssertEqual(AgentRowText.dotToken(.done), .ok)
        XCTAssertEqual(AgentRowText.dotToken(.idle), .muted)
    }

    func testLiveDotsWearAHaloAndFinishedOnesDoNot() {
        XCTAssertEqual(AgentRowText.haloToken(.needsYou), .focusRing)
        XCTAssertEqual(AgentRowText.haloToken(.working), .workingHalo)
        XCTAssertNil(AgentRowText.haloToken(.done))
        XCTAssertNil(AgentRowText.haloToken(.idle))
    }

    func testTheRowIsTheMockupsRow() {
        XCTAssertEqual(OMAgentRow.horizontalPadding, 14)
        XCTAssertEqual(OMAgentRow.verticalPadding, 11)
        XCTAssertEqual(OMAgentRow.lineSpacing, 10)
        XCTAssertEqual(OMAgentRow.dotDiameter, 8)
        XCTAssertEqual(OMAgentRow.haloWidth, 3)
        XCTAssertEqual(OMAgentRow.titleSize, 13)
        XCTAssertEqual(OMAgentRow.subtitleSize, 11.5)
        // The buttons start under the text: past an 8 pt dot, or a 20 pt logo, and 11 pt.
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: false), 19)
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: true), 31)
    }
}
