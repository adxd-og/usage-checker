import XCTest
@testable import Omelette

/// Tester's verification of `StatusItemVisibilityRules.firstLaunchAfterUpdate` (whole-branch review
/// of 4.0, ruling 1): the first launch after an update on a notched Mac opens the island once, with
/// the setting never stored and the tour seen; never on a fresh install or with no notched display.
/// All sixteen inputs against a table written from the ruling.
final class StatusItemFirstLaunchVerificationTests: XCTestCase {
    private typealias Verdict = StatusItemVisibilityRules.FirstLaunchAfterUpdate

    /// marked, seen the tour, a stored setting, a notched display attached.
    private func expected(marked: Bool, seen: Bool, stored: Bool, notch: Bool) -> Verdict {
        if marked { return .nothing }              // once
        if !seen { return .markOnly }              // a fresh install has the tour
        if stored { return .markOnly }             // met the switch
        return notch ? .openIsland : .nothing      // no notch: the item is still there, a later launch decides
    }

    func testEveryCombinationOfTheFourFacts() {
        var runs = 0
        for marked in [false, true] {
            for seen in [false, true] {
                for stored in [false, true] {
                    for notch in [false, true] {
                        // A stored setting of either value reads the same.
                        for value in stored ? [true, false] : [nil] {
                            runs += 1
                            XCTAssertEqual(
                                StatusItemVisibilityRules.firstLaunchAfterUpdate(
                                    alreadyMarked: marked, hasSeenOnboarding: seen, setting: value, islandDisplayAttached: notch
                                ),
                                expected(marked: marked, seen: seen, stored: stored, notch: notch),
                                "marked \(marked), tour seen \(seen), setting \(String(describing: value)), notch \(notch)"
                            )
                        }
                    }
                }
            }
        }
        XCTAssertEqual(runs, 24)
    }

    func testTheOnlyInputThatOpensTheIslandIsAnUpdatedNotchedMacWithNoStoredSetting() {
        var opening: [String] = []
        for marked in [false, true] {
            for seen in [false, true] {
                for setting: Bool? in [nil, true, false] {
                    for notch in [false, true]
                    where StatusItemVisibilityRules.firstLaunchAfterUpdate(
                        alreadyMarked: marked, hasSeenOnboarding: seen, setting: setting, islandDisplayAttached: notch
                    ) == .openIsland {
                        opening.append("\(marked) \(seen) \(String(describing: setting)) \(notch)")
                    }
                }
            }
        }
        XCTAssertEqual(opening, ["false true nil true"])
    }

    /// Once marked, nothing the other facts do brings it back: a launch after the marker is a
    /// plain launch, so the island never opens "on every launch".
    func testAMarkedLaunchNeverOpensWhateverElseChanges() {
        for seen in [false, true] {
            for setting: Bool? in [nil, true, false] {
                for notch in [false, true] {
                    XCTAssertEqual(
                        StatusItemVisibilityRules.firstLaunchAfterUpdate(
                            alreadyMarked: true, hasSeenOnboarding: seen, setting: setting, islandDisplayAttached: notch
                        ),
                        .nothing
                    )
                }
            }
        }
    }
}
