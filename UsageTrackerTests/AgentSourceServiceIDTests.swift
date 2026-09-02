import XCTest
@testable import Omelette

/// The popover finds the agent rows for a provider tab with
/// `AgentSource(rawValue: service.id)`. Nothing in the type system links the two
/// vocabularies, so renaming either side would silently empty the tab — pin them here.
final class AgentSourceServiceIDTests: XCTestCase {
    func testProviderServiceIDsMapToAnAgentSource() {
        XCTAssertEqual(AgentSource(rawValue: ClaudeOAuthProvider.serviceID), .claude)
        XCTAssertEqual(AgentSource(rawValue: CodexProvider.serviceID), .codex)
    }
}
