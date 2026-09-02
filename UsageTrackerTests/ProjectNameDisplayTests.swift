import XCTest
@testable import Omelette

/// `decode(slug:)` guesses a path out of Claude's lossy dash slug. An agent session
/// hands us the real `cwd`, so there is nothing to guess — but the display rules
/// (strip $HOME, drop a noise parent, keep the last two components) must be identical
/// so a hook-tracked row and a cost row name the same project the same way.
final class ProjectNameDisplayTests: XCTestCase {
    func testKeepsTheLastTwoComponents() {
        XCTAssertEqual(ProjectName.display(path: "/Users/tester/Projects/alpha"), "Projects / alpha")
    }

    func testStripsTheHomePrefixAndANoiseParent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ProjectName.display(path: "\(home)/Desktop/Usage tracker"), "Usage tracker")
        XCTAssertEqual(ProjectName.display(path: "\(home)/Desktop/Orion Gate/mobile-app"), "Orion Gate / mobile-app")
    }

    func testASingleComponentPathIsItsOwnName() {
        XCTAssertEqual(ProjectName.display(path: "/opt"), "opt")
    }

    func testARelativeOrEmptyPathIsReturnedUnchanged() {
        // Nothing to prettify and nothing to invent — a hook that sends a relative
        // path is better shown verbatim than turned into a wrong project.
        XCTAssertEqual(ProjectName.display(path: "some/relative/dir"), "some/relative/dir")
        XCTAssertEqual(ProjectName.display(path: ""), "")
    }

    func testSpacesSurviveUnlikeTheSlugPath() {
        // The whole point of the new entry point: "Orion Gate" is a single folder and
        // the dash slug cannot prove that, but the real cwd can.
        XCTAssertEqual(ProjectName.display(path: "/Volumes/Work/Orion Gate"), "Work / Orion Gate")
    }
}
