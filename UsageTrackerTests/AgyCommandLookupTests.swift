import XCTest
@testable import Omelette

/// `AgyCommand.executablePath` (spec 2026-10-16-antigravity-argon § "Package 2", Design:
/// "`AGY_BIN`, then `~/.local/bin/agy`, then `PATH`"). A menu-bar app started by launchd
/// does not inherit the login shell's PATH, so the lookup is a rule on the environment
/// it is given, with no shell. `isExecutable` stands in for the file system.
final class AgyCommandLookupTests: XCTestCase {
    private let home = "/home/omelette"

    private func lookup(_ environment: [String: String], executables: Set<String>) -> String? {
        AgyCommand.executablePath(environment: environment, homeDirectory: home, isExecutable: { executables.contains($0) })
    }

    func testAGYBINWinsWhenItNamesAnExecutable() {
        XCTAssertEqual(
            lookup(["AGY_BIN": "/opt/agy/bin/agy", "PATH": "/usr/local/bin"],
                   executables: ["/opt/agy/bin/agy", "/home/omelette/.local/bin/agy", "/usr/local/bin/agy"]),
            "/opt/agy/bin/agy"
        )
    }

    func testAGYBINUnderTheHomeFolderIsExpanded() {
        XCTAssertEqual(
            lookup(["AGY_BIN": "~/tools/agy"], executables: ["/home/omelette/tools/agy", "/home/omelette/.local/bin/agy"]),
            "/home/omelette/tools/agy"
        )
    }

    func testAnAGYBINWithNothingBehindItFallsThroughToTheLocalBin() {
        XCTAssertEqual(
            lookup(["AGY_BIN": "/opt/agy/bin/agy"], executables: ["/home/omelette/.local/bin/agy"]),
            "/home/omelette/.local/bin/agy"
        )
    }

    func testTheLocalBinComesBeforePATH() {
        XCTAssertEqual(
            lookup(["PATH": "/opt/homebrew/bin:/usr/bin"], executables: ["/opt/homebrew/bin/agy", "/home/omelette/.local/bin/agy"]),
            "/home/omelette/.local/bin/agy"
        )
    }

    func testPATHIsSearchedInOrderSkippingRelativeAndEmptyEntries() {
        XCTAssertEqual(
            lookup(["PATH": "bin::/usr/local/bin/:/opt/homebrew/bin"],
                   executables: ["bin/agy", "/usr/local/bin/agy", "/opt/homebrew/bin/agy"]),
            "/usr/local/bin/agy"
        )
    }

    func testABareAGYBINNameIsIgnored() {
        XCTAssertEqual(
            lookup(["AGY_BIN": "agy", "PATH": "/opt/homebrew/bin"], executables: ["agy", "/opt/homebrew/bin/agy"]),
            "/opt/homebrew/bin/agy"
        )
    }

    func testNoAgyAnywhereIsNil() {
        XCTAssertNil(lookup(["PATH": "/usr/bin:/bin"], executables: []))
        XCTAssertNil(lookup([:], executables: ["/usr/bin/agy"]), "no PATH means no PATH entries")
    }
}
