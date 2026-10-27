import Foundation

/// What the helper or the app could not do, as one sentence (spec 2026-10-26, § Helper › XPC:
/// "A pmset failure comes back as an error the block shows"). Shared by Settings and, in
/// Package 2, the popover block.
enum KeepAwakeFailureCopy {
    static func text(_ failure: KeepAwakeFailure) -> String {
        switch failure {
        case .commandFailed(let command, let status):
            return "\(command) stopped with exit code \(status)."
        case .readBack(expected: true):
            return "The sleep flag did not turn on, so the Mac would still sleep with the lid closed."
        case .readBack(expected: false):
            return "The sleep flag is still on. Reset keep awake in Settings › Advanced clears it."
        case .invalidDuration:
            return "Choose between 1 minute and 7 d 23 h 59 min."
        case .helperUnavailable(let reason):
            return "The keep-awake helper did not answer: \(reason)"
        case .helperTimedOut:
            return "The keep-awake helper did not answer within \(Int(KeepAwakeXPCTransport.timeout)) seconds."
        case .unreadableReply:
            return "The keep-awake helper answered in a form this version cannot read. Restarting the Mac starts the updated helper."
        case .notSigned:
            return "This build is not signed by a developer team, so the keep-awake helper will not talk to it."
        case .registrationFailed(let reason):
            return "The keep-awake helper could not be set up: \(reason)"
        case .unregisterFailed(let reason):
            return "The keep-awake helper could not be removed: \(reason)"
        case .adminCancelled:
            return "No password was given, so the sleep flag is still on."
        case .flagStillSet:
            return "The keep-awake helper stopped but the sleep flag is still on, so this Mac will not sleep. Reset keep awake in Settings › Advanced clears it."
        }
    }
}
