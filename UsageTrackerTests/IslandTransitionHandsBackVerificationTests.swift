import XCTest
@testable import Omelette

/// Tester's verification of `IslandTransition.handsBackAfterClose` (whole-branch review of 4.0,
/// ruling 3): a close hands the keyboard back unless another of the app's windows should stay key,
/// and a reopen keeps its own key policy. All sixteen inputs against the sentence of the ruling.
final class IslandTransitionHandsBackVerificationTests: XCTestCase {
    func testEveryCombinationOfTheFourFacts() {
        var handed = 0
        for wasKey in [false, true] {
            for reopened in [false, true] {
                for active in [false, true] {
                    for other in [false, true] {
                        let got = IslandTransition.handsBackAfterClose(
                            islandWasKey: wasKey, reopened: reopened, appIsActive: active, otherWindowCanTakeKey: other
                        )
                        // Hands back: the island held the keyboard, nothing came back in its place, the app
                        // still holds the activation, and no other window of the app is there to take it.
                        let want = wasKey && !reopened && active && !other
                        XCTAssertEqual(got, want, "wasKey \(wasKey), reopened \(reopened), active \(active), other \(other)")
                        if got { handed += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(handed, 1, "exactly one of the sixteen hands the keyboard back")
    }
}
