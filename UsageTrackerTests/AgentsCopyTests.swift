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
}
