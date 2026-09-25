import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Principles 2: "No tinted chips under text. State is
/// coloured text or a dot." A provider tab's state line.
final class ProviderStateLabelTests: XCTestCase {
    func testALiveProviderHasNoStateLine() {
        XCTAssertNil(PopoverView.stateLabel(for: Fixture.snapshot(id: "claude")))
    }

    func testTheStateIsItsWordInItsColour() {
        XCTAssertEqual(PopoverView.stateLabel(for: Fixture.snapshot(id: "antigravity", state: .notRunning)),
                       OMColoredText(text: "Not running", token: .secondary))
        XCTAssertEqual(PopoverView.stateLabel(for: Fixture.snapshot(id: "codex", state: .notSignedIn)),
                       OMColoredText(text: "Sign in", token: .warning))
        XCTAssertEqual(PopoverView.stateLabel(for: Fixture.snapshot(id: "grok", state: .error)),
                       OMColoredText(text: "Error", token: .critical))
    }
}
