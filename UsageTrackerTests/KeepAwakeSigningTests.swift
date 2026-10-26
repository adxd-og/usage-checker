import XCTest
@testable import Omelette

/// Spec 2026-10-26 § Helper › XPC: "The daemon accepts a connection only when the caller's
/// code satisfies anchor apple generic and identifier "com.usagetracker.app" and certificate
/// leaf[subject.OU] = <team>" — with the team taken from the daemon's own signature (plan D2).
/// `AB12CD34EF` is a made-up team.
final class KeepAwakeSigningTests: XCTestCase {
    func testTheHelperAcceptsOnlyTheAppSignedByItsOwnTeam() {
        XCTAssertEqual(
            KeepAwakeSigning.callerRequirement(teamID: "AB12CD34EF"),
            #"anchor apple generic and identifier "com.usagetracker.app" and certificate leaf[subject.OU] = "AB12CD34EF""#
        )
    }

    func testTheAppAcceptsOnlyAHelperSignedByItsOwnTeam() {
        XCTAssertEqual(
            KeepAwakeSigning.helperRequirement(teamID: "AB12CD34EF"),
            #"anchor apple generic and certificate leaf[subject.OU] = "AB12CD34EF""#
        )
    }

    func testWithoutAProperTeamThereIsNoRequirementAndSoNoConnection() {
        for team in [nil, "", "ab12cd34ef", "AB12CD34E", #"AB12CD34EF" or anchor apple"#] as [String?] {
            XCTAssertNil(KeepAwakeSigning.callerRequirement(teamID: team), "\(team ?? "nil")")
            XCTAssertNil(KeepAwakeSigning.helperRequirement(teamID: team), "\(team ?? "nil")")
        }
    }

    func testTheNamesLaunchdXPCAndTheBundleShareAreOne() {
        XCTAssertEqual(KeepAwakeIdentity.label, "com.usagetracker.app.keepawake")
        XCTAssertEqual(KeepAwakeIdentity.machServiceName, KeepAwakeIdentity.label)
        XCTAssertEqual(KeepAwakeIdentity.plistName, "com.usagetracker.app.keepawake.plist")
        XCTAssertEqual(KeepAwakeIdentity.helperName, "omelette-keepawake")
        XCTAssertEqual(KeepAwakeIdentity.appIdentifier, "com.usagetracker.app")
        XCTAssertEqual(KeepAwakeIdentity.stateFileURL.path, "/Library/Application Support/Omelette/keepawake.json")
    }
}
