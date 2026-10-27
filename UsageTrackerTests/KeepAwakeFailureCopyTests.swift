import XCTest
@testable import Omelette

/// Spec 2026-10-26 § Helper › XPC: "A pmset failure comes back as an error the block shows";
/// § UI: Settings › Advanced shows what the reset could not do. One sentence per failure,
/// shared by Settings and (Package 2) the popover block.
final class KeepAwakeFailureCopyTests: XCTestCase {
    func testEveryFailureReadsAsASentence() {
        let expected: [(KeepAwakeFailure, String)] = [
            (.commandFailed(command: "pmset", status: 1), "pmset stopped with exit code 1."),
            (.readBack(expected: true), "The sleep flag did not turn on, so the Mac would still sleep with the lid closed."),
            (.readBack(expected: false), "The sleep flag is still on. Reset keep awake in Settings › Advanced clears it."),
            (.invalidDuration, "Choose between 1 minute and 7 d 23 h 59 min."),
            (.helperUnavailable(reason: "Couldn’t communicate with a helper application."), "The keep-awake helper did not answer: Couldn’t communicate with a helper application."),
            (.helperTimedOut, "The keep-awake helper did not answer within 10 seconds."),
            (.unreadableReply, "The keep-awake helper answered in a form this version cannot read. Restarting the Mac starts the updated helper."),
            (.notSigned, "This build is not signed by a developer team, so the keep-awake helper will not talk to it."),
            (.registrationFailed(reason: "Operation not permitted"), "The keep-awake helper could not be set up: Operation not permitted"),
            (.unregisterFailed(reason: "Service not found"), "The keep-awake helper could not be removed: Service not found"),
            (.adminCancelled, "No password was given, so the sleep flag is still on."),
            (.flagStillSet, "The keep-awake helper stopped but the sleep flag is still on, so this Mac will not sleep. Reset keep awake in Settings › Advanced clears it."),
        ]
        for (failure, text) in expected {
            XCTAssertEqual(KeepAwakeFailureCopy.text(failure), text)
        }
    }
}
