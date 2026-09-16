import XCTest
@testable import Omelette

/// The address a tmux pane is named by, parsed out of the two variables tmux exports
/// into every shell it starts. Covers the "Address" section of
/// docs/superpowers/specs/2026-09-17-tmux-jump-design.md.
final class TmuxAddressTests: XCTestCase {
    /// What a shell inside a pane really carries (tmux 3.7c, socket path, server pid,
    /// session index).
    private let full = [
        "TMUX": "/private/tmp/tmux-501/default,45727,0",
        "TMUX_PANE": "%3",
    ]

    func testAShellInsideAPaneCarriesAWholeAddress() {
        XCTAssertEqual(
            TmuxAddress.parse(environment: full),
            TmuxAddress(socketPath: "/private/tmp/tmux-501/default", serverPID: 45727, pane: "%3")
        )
    }

    func testWithoutAPaneThereIsNoAddress() {
        // $TMUX alone says a tmux is running somewhere, not which pane we are in.
        XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": full["TMUX"]!]))
        XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": full["TMUX"]!, "TMUX_PANE": ""]))
    }

    func testWithoutTmuxThereIsNoAddress() {
        XCTAssertNil(TmuxAddress.parse(environment: [:]))
        XCTAssertNil(TmuxAddress.parse(environment: ["TMUX_PANE": "%3"]))
        XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": "", "TMUX_PANE": "%3"]))
    }

    func testATmuxVariableWithoutItsFieldsIsNotAnAddress() {
        for raw in ["/private/tmp/tmux-501/default", "/private/tmp/tmux-501/default,", ",45727,0", ",,"] {
            XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": raw, "TMUX_PANE": "%3"]), raw)
        }
    }

    func testAServerPIDThatIsNotAPIDIsNotAnAddress() {
        for raw in ["/tmp/s,notapid,0", "/tmp/s,0,0", "/tmp/s,-4,0", "/tmp/s,99999999999,0"] {
            XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": raw, "TMUX_PANE": "%3"]), raw)
        }
    }

    /// The pane id is pasted into a tmux command line, so anything that is not
    /// `%<digits>` is refused rather than passed along.
    func testOnlyAPercentAndDigitsIsAPaneID() {
        XCTAssertTrue(TmuxAddress.isPaneID("%0"))
        XCTAssertTrue(TmuxAddress.isPaneID("%17"))
        for value in ["3", "%", "%a", "%3x", "%-1", "% 3", "%3 ", "pane", "%٣"] {
            XCTAssertFalse(TmuxAddress.isPaneID(value), value)
            XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": full["TMUX"]!, "TMUX_PANE": value]), value)
        }
    }

    /// A socket path with a comma in it would split wrong; the first field is the
    /// path tmux itself wrote, and tmux never puts a comma there. What matters is
    /// that extra fields never break the parse.
    func testExtraFieldsAreIgnored() {
        XCTAssertEqual(
            TmuxAddress.parse(environment: ["TMUX": "/tmp/s,45727,0,something", "TMUX_PANE": "%3"]),
            TmuxAddress(socketPath: "/tmp/s", serverPID: 45727, pane: "%3")
        )
    }
}
