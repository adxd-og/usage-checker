import XCTest
import Darwin
@testable import Omelette

/// Tester's verification of the rename's link rules (plan 2026-10-31-brioche-rename, R2 to R4):
/// what counts as foreign at a CLI link, what a refresh does to each kind of thing it finds,
/// what a new setup is handed, and what the identity constants still say.
final class AgentPathsBriocheVerificationTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private var target: URL!
    private var immutablePaths: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPathsBriocheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        target = root.appendingPathComponent("Brioche.app/Contents/Helpers/omelette")
    }

    override func tearDownWithError() throws {
        for path in immutablePaths { _ = lchflags(path, 0) }
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { bin.appendingPathComponent(name) }

    private func link(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(name).path, withDestinationPath: destination)
    }

    private func destination(_ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url(name).path)
    }

    private func makeImmutable(_ name: String) {
        immutablePaths.append(url(name).path)
        XCTAssertEqual(lchflags(url(name).path, UInt32(UF_IMMUTABLE)), 0, "could not pin \(name)")
    }

    private func exists(_ name: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path)) != nil
    }

    // MARK: - cliLinkIsForeign

    func testWhatIsOursAtACLILinkAndWhatIsNot() throws {
        let realEarlier = root.appendingPathComponent("Old/Omelette.app/Contents/Helpers/omelette")
        try FileManager.default.createDirectory(at: realEarlier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: realEarlier)
        let someFile = root.appendingPathComponent("somewhere-else")
        try Data("x".utf8).write(to: someFile)
        let someDirectory = root.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: someDirectory, withIntermediateDirectories: true)

        // (name at the link's path, what is there, is it foreign, how to make it)
        let cases: [(String, String, Bool, () throws -> Void)] = [
            ("nothing", "nothing", false, {}),
            ("ours", "a link to this bundle's binary", false, { try self.link("ours", to: self.target.path) }),
            ("earlier-real", "a link to an earlier copy that still exists", false, { try self.link("earlier-real", to: realEarlier.path) }),
            ("earlier-gone", "a link to an earlier copy that is gone", false, { try self.link("earlier-gone", to: "/Applications/Omelette.app/Contents/Helpers/omelette") }),
            ("relative-ours", "a relative link ending like our binary", false, { try self.link("relative-ours", to: "../Brioche.app/Contents/Helpers/omelette") }),
            ("relative-other", "a relative link to something else", true, { try self.link("relative-other", to: "../elsewhere/brioche") }),
            ("file", "a regular file", true, { try Data("#!/bin/sh\n".utf8).write(to: self.url("file")) }),
            ("empty", "an empty regular file", true, { try Data().write(to: self.url("empty")) }),
            ("dir", "a directory", true, { try FileManager.default.createDirectory(at: self.url("dir"), withIntermediateDirectories: true) }),
            ("other-file", "a link to another existing file", true, { try self.link("other-file", to: someFile.path) }),
            ("other-dir", "a link to a directory", true, { try self.link("other-dir", to: someDirectory.path) }),
            ("other-dangling", "a dangling link to another tool", true, { try self.link("other-dangling", to: "/opt/brioche/bin/brioche") }),
            ("hook", "a link to our hook helper", true, { try self.link("hook", to: "/Applications/X.app/Contents/Helpers/omelette-hook") }),
            ("keepawake", "a link to our keep-awake helper", true, { try self.link("keepawake", to: "/Applications/X.app/Contents/Helpers/omelette-keepawake") }),
            ("below", "a link into a directory called omelette", true, { try self.link("below", to: "/x/Contents/Helpers/omelette/brioche") }),
        ]
        for (name, label, foreign, make) in cases {
            try make()
            XCTAssertEqual(AgentPaths.cliLinkIsForeign(url(name), target: target), foreign, label)
        }
    }

    func testALinkEqualToTheTargetIsOursWhateverTheTargetIsCalled() throws {
        let custom = root.appendingPathComponent("somewhere/not-our-usual-name")
        try link("brioche", to: custom.path)

        XCTAssertFalse(AgentPaths.cliLinkIsForeign(url("brioche"), target: custom))
        XCTAssertTrue(AgentPaths.cliLinkIsForeign(url("brioche"), target: target))
    }

    // MARK: - refreshCLISymlink leaves each foreign thing exactly alone, and takes each of ours

    func testARefreshChangesNothingForAnyKindOfForeignThing() throws {
        let theirs = Data("another tool".utf8)
        try theirs.write(to: url("file"))
        try FileManager.default.createDirectory(at: url("dir"), withIntermediateDirectories: true)
        try Data("in".utf8).write(to: url("dir").appendingPathComponent("inside"))
        try link("other", to: "/opt/homebrew/bin/brioche")
        try link("hook", to: "/Applications/X.app/Contents/Helpers/omelette-hook")

        for name in ["file", "dir", "other", "hook"] {
            XCTAssertFalse(try AgentPaths.refreshCLISymlink(link: url(name), target: target), name)
        }

        XCTAssertEqual(try Data(contentsOf: url("file")), theirs)
        XCTAssertEqual(try Data(contentsOf: url("dir").appendingPathComponent("inside")), Data("in".utf8))
        XCTAssertEqual(destination("other"), "/opt/homebrew/bin/brioche")
        XCTAssertEqual(destination("hook"), "/Applications/X.app/Contents/Helpers/omelette-hook")
    }

    func testARefreshRepointsEveryKindOfLinkOfOurs() throws {
        try link("gone", to: "/Applications/Omelette.app/Contents/Helpers/omelette")
        try link("relative", to: "../Brioche.app/Contents/Helpers/omelette")

        XCTAssertTrue(try AgentPaths.refreshCLISymlink(link: url("gone"), target: target))
        XCTAssertTrue(try AgentPaths.refreshCLISymlink(link: url("relative"), target: target))
        XCTAssertFalse(try AgentPaths.refreshCLISymlink(link: url("gone"), target: target), "idempotent")

        XCTAssertEqual(destination("gone"), target.path)
        XCTAssertEqual(destination("relative"), target.path)
    }

    func testTheHookHelpersLinkStillReplacesWhatIsInItsWay() throws {
        let hook = url("omelette-hook")
        let helper = root.appendingPathComponent("Brioche.app/Contents/Helpers/omelette-hook")
        try Data("a foreign file".utf8).write(to: hook)

        XCTAssertTrue(try AgentPaths.refreshHelperSymlink(link: hook, target: helper))

        XCTAssertEqual(destination("omelette-hook"), helper.path)
    }

    // MARK: - refreshCLISymlinks

    func testRefreshingBothNamesTwiceIsQuietAndKeepsBoth() throws {
        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target)
        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target)

        XCTAssertEqual(destination("brioche"), target.path)
        XCTAssertEqual(destination("omelette"), target.path)
    }

    func testBothNamesTakenLeavesBothAndDoesNotThrow() throws {
        try Data("one".utf8).write(to: url("brioche"))
        try link("omelette", to: "/opt/other/omelette")

        XCTAssertNoThrow(try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target))

        XCTAssertEqual(try Data(contentsOf: url("brioche")), Data("one".utf8))
        XCTAssertEqual(destination("omelette"), "/opt/other/omelette")
    }

    func testAStaleOmeletteIsRepointedWhileBriocheIsForeign() throws {
        try Data("one".utf8).write(to: url("brioche"))
        try link("omelette", to: "/Applications/Omelette.app/Contents/Helpers/omelette")

        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target)

        XCTAssertEqual(destination("omelette"), target.path, "a status line that runs omelette must follow the app")
    }

    func testWhenBriocheCannotBeRefreshedOmeletteIsStillMadeAndTheFailureSurfaces() throws {
        try link("brioche", to: "/Applications/Omelette.app/Contents/Helpers/omelette")
        makeImmutable("brioche")

        XCTAssertThrowsError(try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target))

        XCTAssertEqual(destination("omelette"), target.path, "one failing link must not stop the other")
    }

    func testWhenOmeletteCannotBeRefreshedBriocheIsStillMadeAndTheFailureSurfaces() throws {
        try link("omelette", to: "/Applications/Omelette.app/Contents/Helpers/omelette")
        makeImmutable("omelette")

        XCTAssertThrowsError(try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target))

        XCTAssertEqual(destination("brioche"), target.path, "one failing link must not stop the other")
    }

    // MARK: - usableCLILink and bothCLINamesForeign

    func testWhatANewSetupIsHandedForEveryStateOfBrioche() throws {
        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target), url("brioche"), "nothing there")

        try link("brioche", to: target.path)
        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target), url("brioche"), "ours")
        try FileManager.default.removeItem(at: url("brioche"))

        try link("brioche", to: "/Applications/Gone.app/Contents/Helpers/omelette")
        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target), url("brioche"), "ours, from an earlier copy")
        try FileManager.default.removeItem(at: url("brioche"))

        try link("brioche", to: "/opt/homebrew/bin/brioche")
        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target), url("omelette"), "a dangling link of another tool")
        try FileManager.default.removeItem(at: url("brioche"))

        try FileManager.default.createDirectory(at: url("brioche"), withIntermediateDirectories: true)
        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target), url("omelette"), "a directory")
    }

    func testOnlyBothNamesTakenTurnsTheInstallersOff() throws {
        XCTAssertFalse(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target), "neither")

        try Data("a".utf8).write(to: url("omelette"))
        XCTAssertFalse(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target), "only omelette: brioche is free")

        try FileManager.default.removeItem(at: url("omelette"))
        try link("brioche", to: "/opt/homebrew/bin/brioche")
        XCTAssertFalse(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target), "only brioche: omelette is free")

        try FileManager.default.createDirectory(at: url("omelette"), withIntermediateDirectories: true)
        XCTAssertTrue(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target), "a dangling foreign link and a directory")

        try FileManager.default.removeItem(at: url("omelette"))
        try link("omelette", to: target.path)
        XCTAssertFalse(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target), "omelette is ours")
    }

    // MARK: - identity

    func testTheNamesAndPathsAnUpdateRelaysOn() {
        XCTAssertEqual(AgentPaths.cliName, "brioche")
        XCTAssertEqual(AgentPaths.legacyCLIName, "omelette")
        XCTAssertEqual(AgentPaths.helperName, "omelette-hook")
        XCTAssertEqual(AgentPaths.cliSymlinkURL.lastPathComponent, "brioche")
        XCTAssertEqual(AgentPaths.legacyCLISymlinkURL.lastPathComponent, "omelette")
        XCTAssertEqual(AgentPaths.helperSymlinkURL.lastPathComponent, "omelette-hook")
        XCTAssertEqual(AgentPaths.cliSymlinkURL.deletingLastPathComponent(), AgentPaths.legacyCLISymlinkURL.deletingLastPathComponent())
        XCTAssertEqual(AgentPaths.appSupportURL.lastPathComponent, "UsageTracker")
        XCTAssertEqual(AgentPaths.binURL.deletingLastPathComponent(), AgentPaths.appSupportURL)
        XCTAssertEqual(AgentPaths.bundledCLIURL.lastPathComponent, "omelette", "the binary keeps its name so bin/omelette never dangles")
        XCTAssertEqual(AgentPaths.bundledHelperURL.lastPathComponent, "omelette-hook")
        XCTAssertEqual(AgentPaths.socketEnvironmentKey, "OMELETTE_AGENT_SOCKET")
    }

    func testTheOtherNameInTheSameFolderKeepsTheFolder() {
        XCTAssertEqual(
            AgentPaths.legacyCLIPath(for: "/Users/tester/Library/Application Support/UsageTracker/bin/brioche"),
            "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"
        )
        XCTAssertEqual(AgentPaths.legacyCLIPath(for: "/a b/c/omelette"), "/a b/c/omelette")
    }
}
