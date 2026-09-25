import XCTest
@testable import Omelette

/// Which providers have chats at all: History draws its chat list for them alone.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4;
/// docs/superpowers/specs/2026-09-24-liquid-glass-redesign.md § Screens, "History · Chart".
final class SessionHistoryModeTests: XCTestCase {
    func testOnlyTheTwoProvidersWhoseLogsIdentifyAChatGetAChatList() {
        // Grok writes a per-turn cost log — DashboardState.costSource says so — but
        // nothing in it names a chat, so its sessions() answers [] forever.
        XCTAssertTrue(DashboardState.hasSessionLog(for: "claude"))
        XCTAssertTrue(DashboardState.hasSessionLog(for: "codex"))
        XCTAssertFalse(DashboardState.hasSessionLog(for: "grok"))
        XCTAssertFalse(DashboardState.hasSessionLog(for: "gemini"))
        XCTAssertFalse(DashboardState.hasSessionLog(for: "antigravity"))
    }
}
