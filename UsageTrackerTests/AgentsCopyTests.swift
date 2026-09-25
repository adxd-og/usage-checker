import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Agents", and `Dashboard-Agents(-Light).dc.html`: every
/// word the Agents tab draws, as the mockup spells it.
final class AgentsCopyTests: XCTestCase {
    func testTheScreenIsTitledAgents() {
        XCTAssertEqual(AgentsCopy.title, "Agents")
    }

    func testVoiceOverCallsTheSourceFilterTheSource() {
        XCTAssertEqual(AgentsCopy.sourcePickerName, "Source")
    }

    // MARK: Live card

    func testTheLiveCardIsTitledLiveInSentenceCase() {
        XCTAssertEqual(AgentsCopy.liveTitle, "Live")
    }

    func testTheLiveCountIsPluralised() {
        XCTAssertEqual(AgentsCopy.liveCount(1), "1 session")
        XCTAssertEqual(AgentsCopy.liveCount(3), "3 sessions")
    }

    func testNoLiveSessionsDrawsNoCountBecauseTheEmptyRowSaysIt() {
        XCTAssertNil(AgentsCopy.liveCount(0))
        XCTAssertEqual(AgentsCopy.liveEmpty, "No agent sessions")
    }
}
