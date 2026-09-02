import XCTest
@testable import Omelette

final class SessionActivatorTests: XCTestCase {
    func testTerminalScriptSelectsTheTabWithThatTTY() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.apple.Terminal", tty: "/dev/ttys004"))
        XCTAssertTrue(source.contains("\"/dev/ttys004\""), source)
        XCTAssertTrue(source.contains("application id \"com.apple.Terminal\""), source)
        XCTAssertTrue(source.contains("tabs of w"), source)
        XCTAssertTrue(source.contains("set selected of t to true"), source)
        XCTAssertTrue(source.contains("set frontmost of w to true"), source)
        XCTAssertTrue(source.contains("with timeout of 2 seconds"), source)
    }

    func testITermScriptWalksWindowsTabsSessions() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.googlecode.iterm2", tty: "/dev/ttys011"))
        XCTAssertTrue(source.contains("\"/dev/ttys011\""), source)
        XCTAssertTrue(source.contains("application id \"com.googlecode.iterm2\""), source)
        XCTAssertTrue(source.contains("tabs of w"), source)
        XCTAssertTrue(source.contains("sessions of t"), source)
        XCTAssertTrue(source.contains("select s"), source)
        XCTAssertTrue(source.contains("with timeout of 2 seconds"), source)
    }

    func testUnsupportedTerminalsGetNoScript() {
        XCTAssertNil(SessionActivator.script(for: "com.mitchellh.ghostty", tty: "/dev/ttys004"))
        XCTAssertNil(SessionActivator.script(for: "com.microsoft.VSCode", tty: "/dev/ttys004"))
        XCTAssertNil(SessionActivator.script(for: "", tty: "/dev/ttys004"))
    }

    /// The tty reaches us over the hook socket. It is machine-generated today,
    /// but a quote in it must not be able to close the AppleScript literal.
    func testQuotesInTheTTYCannotEscapeTheStringLiteral() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.apple.Terminal", tty: "/dev/tty\"s004"))
        XCTAssertTrue(source.contains("\\\"s004"), source)
        XCTAssertFalse(source.contains("tty\"s004"), source)
    }

    func testBackslashesInTheTTYAreEscaped() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.googlecode.iterm2", tty: "/dev/tty\\s004"))
        XCTAssertTrue(source.contains("tty\\\\s004"), source)
    }
}
