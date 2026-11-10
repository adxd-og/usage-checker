import XCTest
@testable import Omelette

/// The inputs and paths the hook-input hardening rules imply beyond the package's own
/// tests. Covers § Design › Tmux address and § Design › Status line strings of
/// docs/superpowers/specs/2026-11-10-hook-input-hardening.md, and § What does not
/// change (the fallback order, the absent case, the strings that stay trim-only).
final class HookInputHardeningVerificationTests: XCTestCase {
    // MARK: - Tmux address

    private func host(
        socket: String? = "/private/tmp/tmux-501/default",
        pane: String? = "%3",
        binary: String? = "/opt/homebrew/bin/tmux"
    ) -> AgentHostInfo {
        AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys012",
                      tmuxSocket: socket, tmuxPane: pane, tmuxBinary: binary)
    }

    private func exists(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    func testAHostileEnvelopeDecodedFromTheWireIsRefusedAtTheClick() throws {
        // The app does not repeat the helper's check when it reads an envelope: the
        // decoded host carries whatever arrived, and the target is where it is refused.
        let json = """
        {"tty":"/dev/ttys012","tmux_socket":"/private/tmp/tmux-501/default",
         "tmux_pane":"%3 -x","tmux_bin":"/tmp/evil/run.sh"}
        """
        let decoded = try JSONDecoder().decode(AgentHostInfo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tmuxPane, "%3 -x")
        XCTAssertEqual(decoded.tmuxBinary, "/tmp/evil/run.sh")
        let onDisk = exists(["/tmp/evil/run.sh", "/usr/bin/tmux"])
        XCTAssertNil(SessionActivator.tmuxTarget(for: decoded, binaryExists: onDisk), "a pane that is not a pane id")

        var badBinaryOnly = decoded
        badBinaryOnly.tmuxPane = "%3"
        let target = SessionActivator.tmuxTarget(for: badBinaryOnly, binaryExists: onDisk)
        XCTAssertEqual(target?.binary, "/usr/bin/tmux", "the script is never the program; the guess is")
        XCTAssertEqual(target?.pane, "%3")
    }

    func testTheNameTmuxIsMatchedCaseSensitivelyAndWholeComponent() {
        for path in ["/usr/bin/TMUX", "/usr/bin/Tmux", "/usr/bin/tmux ", "/usr/bin/tmux\n", "/usr/bin/xtmux"] {
            XCTAssertFalse(SessionActivator.isTmuxBinary(path, exists: { _ in true }), path)
        }
    }

    func testAPathWithSpacesInItsDirectoriesIsStillATmux() {
        // Over-tightening guard: the rule is the name and the disk, not the characters.
        let path = "/Users/someone/My Tools/bin/tmux"
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: host(binary: path), binaryExists: exists([path]))?.binary,
            path
        )
    }

    func testAnEmptyReportedBinaryIsTheAbsentCase() {
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: host(binary: ""), binaryExists: exists(["/usr/local/bin/tmux"]))?.binary,
            "/usr/local/bin/tmux"
        )
        XCTAssertNil(SessionActivator.tmuxTarget(for: host(binary: ""), binaryExists: exists([])))
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: host(binary: nil), binaryExists: exists(["/usr/local/bin/tmux"]))?.binary,
            "/usr/local/bin/tmux"
        )
    }

    func testARejectedBinaryFallsToTheGuessesInTheirOrder() {
        let all = Set(SessionActivator.tmuxBinaryFallbacks)
        for rejected in ["/tmp/x/run.sh", "relative/tmux", "/opt/local/bin/tmux"] {
            // The last one is a tmux name that is simply not on this disk.
            XCTAssertEqual(
                SessionActivator.tmuxTarget(for: host(binary: rejected), binaryExists: exists(all))?.binary,
                SessionActivator.tmuxBinaryFallbacks[0], rejected
            )
        }
        let withoutFirst = all.subtracting([SessionActivator.tmuxBinaryFallbacks[0]])
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: host(binary: "/tmp/x/run.sh"), binaryExists: exists(withoutFirst))?.binary,
            SessionActivator.tmuxBinaryFallbacks[1]
        )
    }

    func testTheDiskIsAskedAboutTheReportedPathExactlyAsReported() {
        var asked: [String] = []
        let path = "/nix/store/abc-tmux-3.5/bin/tmux"
        let target = SessionActivator.tmuxTarget(for: host(binary: path), binaryExists: { asked.append($0); return $0 == path })
        XCTAssertEqual(target?.binary, path)
        XCTAssertTrue(asked.contains(path))
        XCTAssertFalse(asked.contains(where: { $0 != path }), "an accepted reported path ends the search: \(asked)")
    }

    func testAPaneIDIsAsciiDigitsAfterAPercentAndNothingElse() {
        let onDisk = exists(["/opt/homebrew/bin/tmux"])
        for pane in ["%\u{FF13}", "%3\u{0301}", "%3\u{0}", "%3\r\n", "%-1", "%+3", "%3 ", "%0x3", "%3%4", "%%3", "", "%\u{200B}3"] {
            XCTAssertNil(SessionActivator.tmuxTarget(for: host(pane: pane), binaryExists: onDisk), pane.debugDescription)
        }
        for pane in ["%0", "%7", "%120", "%007"] {
            XCTAssertEqual(SessionActivator.tmuxTarget(for: host(pane: pane), binaryExists: onDisk)?.pane, pane)
        }
    }

    func testAPaneIDNeedsItsPercentSignNotJustAFirstCharacterAndDigits() {
        // `-3` would be a flag-shaped argument for tmux; `33` and `x3` are not pane ids.
        let onDisk = exists(["/opt/homebrew/bin/tmux"])
        for pane in ["33", "-3", "x3", "#3", "$3", "@3"] {
            XCTAssertNil(SessionActivator.tmuxTarget(for: host(pane: pane), binaryExists: onDisk), pane)
        }
    }

    func testAMissingSocketIsStillNoTargetWhateverElseIsValid() {
        let onDisk = exists(["/opt/homebrew/bin/tmux"])
        XCTAssertNil(SessionActivator.tmuxTarget(for: host(socket: nil), binaryExists: onDisk))
        XCTAssertNil(SessionActivator.tmuxTarget(for: host(socket: ""), binaryExists: onDisk))
        XCTAssertNil(SessionActivator.tmuxTarget(for: host(pane: nil), binaryExists: onDisk))
    }

    func testARouteWithARejectedBinaryStillJumpsThroughTheGuess() {
        let onDisk = exists(["/usr/bin/tmux", "/tmp/x/run.sh"])
        XCTAssertEqual(
            SessionActivator.route(for: host(binary: "/tmp/x/run.sh"), tmuxBinaryExists: onDisk),
            .tmux(SessionActivator.TmuxTarget(socketPath: "/private/tmp/tmux-501/default",
                                              pane: "%3", binary: "/usr/bin/tmux"))
        )
    }

    func testAMalformedPaneDoesNotTakeTheCmuxRouteDownWithIt() {
        var h = host(pane: "%3;kill-server")
        h.cmuxWorkspace = "ws-1"
        h.cmuxSurface = "sf-1"
        h.cmuxSocket = "/tmp/cmux.sock"
        XCTAssertEqual(
            SessionActivator.route(for: h, tmuxBinaryExists: exists(["/opt/homebrew/bin/tmux"])),
            .cmux(SessionActivator.CmuxTarget(workspace: "ws-1", surface: "sf-1", socketPath: "/tmp/cmux.sock"))
        )
    }

    // MARK: - Status line strings

    private func input(_ json: String) -> StatusLineInput {
        StatusLineInput.parse(Data(json.utf8))
    }

    /// `\uXXXX` as the JSON text a payload would carry.
    private func escaped(_ scalar: UInt32) -> String {
        String(format: "\\u%04x", scalar)
    }

    func testEveryControlScalarIsDroppedFromInsideAName() {
        let controls = Array(0x00...0x1F) + [0x7F] + Array(0x80...0x9F)
        for scalar in controls {
            let parsed = input(#"{"model":{"display_name":"Fa\#(escaped(UInt32(scalar)))ble"}}"#)
            XCTAssertEqual(parsed.model, "Fable", "U+\(String(scalar, radix: 16))")
        }
    }

    func testTheScalarsNextToTheControlRangesStay() {
        // U+0020 and U+0021 above C0, U+007E below DEL, U+00A0 and U+00A1 above C1.
        XCTAssertEqual(input(#"{"model":{"display_name":"A !~B"}}"#).model, "A !~B")
        XCTAssertEqual(input(#"{"model":{"display_name":"A B"}}"#).model, "A\u{A0}B")
        XCTAssertEqual(input(#"{"model":{"display_name":"¡Fable!"}}"#).model, "\u{A1}Fable!")
    }

    func testOnlyCategoryCcGoesNotTheFormatCharactersAUnicodeNameNeeds() {
        // Spec: "every Unicode scalar of general category `Cc`". A joiner (Cf) holds an
        // emoji sequence together; dropping it would change the name's letters.
        let family = "\u{1F468}\u{200D}\u{1F469}"
        XCTAssertEqual(input("{\"model\":{\"display_name\":\"Fable \(family)\"}}").model, "Fable " + family)
    }

    func testAnOrdinaryNameIsUntouched() {
        XCTAssertEqual(input(#"{"model":{"display_name":"Opus 4.5"}}"#).model, "Opus 4.5")
        XCTAssertEqual(input(#"{"model":{"display_name":"  Opus  4.5  "}}"#).model, "Opus  4.5")
        XCTAssertEqual(input(#"{"model":{"display_name":"Fäble 🥐 模型"}}"#).model, "Fäble 🥐 模型")
    }

    func testAHostileNameCarriesNoEscapeOntoTheColouredLine() {
        let parsed = input(#"{"model":{"display_name":"\u001b]0;pwned\u0007\u001b[2JFable"},"context_window":{"used_percentage":10}}"#)
        let line = StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000), input: parsed, colour: true
        )
        var rest = line
        let constants = [StatusLineText.ANSI.model, StatusLineText.ANSI.reset, StatusLineText.ANSI.roomy,
                         StatusLineText.ANSI.filling, StatusLineText.ANSI.tight, StatusLineText.ANSI.percent]
        for constant in constants {
            rest = rest.replacingOccurrences(of: constant, with: "")
        }
        XCTAssertFalse(rest.unicodeScalars.contains { $0.properties.generalCategory == .control },
                       "only the renderer's own colour codes remain: \(line.debugDescription)")
        XCTAssertTrue(rest.hasPrefix("]0;pwned[2JFable "), rest.debugDescription)
    }

    func testTheOtherStringsOfTheInputStayTrimOnly() {
        // prompt_id, version and the cache ttl are carried or compared, never printed.
        let parsed = input("""
        {"prompt_id":" p\\u001b1 ","version":"\\u00072.5.0 ",
         "prompt_cache":{"warm":true,"caching_observed":true,"ttl":" 5\\u001bm\\n"}}
        """)
        XCTAssertEqual(parsed.promptID, "p\u{1B}1")
        XCTAssertEqual(parsed.version, "\u{07}2.5.0")
        XCTAssertEqual(parsed.promptCache?.ttl, "5\u{1B}m")
    }

    func testANameThatIsNotAStringIsStillNoName() {
        XCTAssertNil(input(#"{"model":{"display_name":42}}"#).model)
        XCTAssertNil(input(#"{"model":{"display_name":["Fable"]}}"#).model)
        XCTAssertNil(input(#"{"model":"\u001bFable"}"#).model, "the id-as-string shape is not the name")
    }
}
