import XCTest
@testable import Omelette

/// A chat row in History is a control: its chevron and name are a button that Tab
/// reaches and Space presses, and VoiceOver hears what pressing it does. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — Keyboard; report D § 4.
final class SessionRowActionTests: XCTestCase {
    func testAClosedChatOffersToShowItsBreakdown() {
        XCTAssertEqual(SessionCopy.rowActionName(expanded: false), "Show this chat's breakdown")
    }

    func testAnOpenChatOffersToHideIt() {
        XCTAssertEqual(SessionCopy.rowActionName(expanded: true), "Hide this chat's breakdown")
    }
}
