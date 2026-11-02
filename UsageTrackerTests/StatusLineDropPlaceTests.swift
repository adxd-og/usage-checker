import XCTest
@testable import Omelette

/// Where the status line's reading drop goes and what its file is called (spec
/// 2026-11-02 Claude limits from the status line, § Design › Wire): beside
/// `status.json` unless the environment says otherwise, one file per session, named by
/// an id that is nothing but ASCII letters, digits and hyphens. Pure: the URLs are
/// never touched on disk.
final class StatusLineDropPlaceTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/StatusLineDropPlaceTests-home", isDirectory: true)

    func testTheDropLivesBesideStatusJSON() {
        XCTAssertEqual(
            StatusLineDrop.defaultDirectoryURL(home: home).path,
            "/tmp/StatusLineDropPlaceTests-home/Library/Application Support/UsageTracker/statusline"
        )
        XCTAssertEqual(
            StatusLineDrop.defaultDirectoryURL(home: home).deletingLastPathComponent().path,
            StatusFile.defaultURL(home: home).deletingLastPathComponent().path,
            "one spelling of Brioche's Application Support folder"
        )
    }

    /// The tests' way out of the real Application Support, spelled like the status
    /// file's own override and independent of it.
    func testTheEnvironmentRedirectsTheDrop() {
        let fallback = StatusLineDrop.defaultDirectoryURL(home: home).path
        XCTAssertEqual(
            StatusLineDrop.directoryURL(
                environment: ["OMELETTE_STATUSLINE_DIR": "/tmp/elsewhere/statusline"], home: home
            ).path,
            "/tmp/elsewhere/statusline"
        )
        XCTAssertEqual(
            StatusLineDrop.directoryURL(environment: ["OMELETTE_STATUSLINE_DIR": ""], home: home).path,
            fallback,
            "an empty override is no override, as with OMELETTE_STATUS_FILE"
        )
        XCTAssertEqual(StatusLineDrop.directoryURL(environment: [:], home: home).path, fallback)
        XCTAssertEqual(
            StatusLineDrop.directoryURL(
                environment: [StatusFile.environmentKey: "/tmp/elsewhere/status.json"], home: home
            ).path,
            fallback,
            "moving the status file does not move the drop"
        )
    }

    func testASessionIDBecomesItsFileName() {
        XCTAssertEqual(
            StatusLineDrop.fileName(sessionID: "0f3a5c1e-7b2d-4a91-8c6f-2d5e9b0a4c73"),
            "0f3a5c1e-7b2d-4a91-8c6f-2d5e9b0a4c73.json"
        )
        XCTAssertEqual(StatusLineDrop.fileName(sessionID: "ABCxyz019"), "ABCxyz019.json")
    }

    /// Checked, never cleaned: an id with anything else is no file at all. Nothing that
    /// climbs out of the folder, hides a file, or spells one name two ways.
    func testASessionIDWithAnythingElseIsNoFileName() {
        for id in [
            "",
            ".",
            "..",
            "../status",
            "a/b",
            "a\\b",
            "a.b",
            "a b",
            "a_b",
            "a:b",
            "~",
            "abc\n",
            "a\u{0}b",
            "café",
            "ａｂｃ",
            "١٢٣",
        ] {
            XCTAssertNil(StatusLineDrop.fileName(sessionID: id), id.debugDescription)
        }
    }
}
