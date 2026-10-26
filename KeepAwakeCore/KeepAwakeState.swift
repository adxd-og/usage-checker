import Foundation

/// Why an armed mode ended.
enum KeepAwakeEndReason: String, Codable, Equatable, Sendable, CaseIterable {
    case deadline
    case batteryFloor
    case cancelled
    /// The daemon started again (a reboot, a crash) and cleared the flag.
    case restarted
    /// launchd stopped the helper (unload, the Login Items switch, unregister); written by
    /// the SIGTERM path.
    case stopped
}

/// What the daemon reports and persists; the app mirrors it.
enum KeepAwakeState: Codable, Equatable, Sendable {
    case idle
    case armed(deadline: Date, floorEnabled: Bool)
    case ended(at: Date, reason: KeepAwakeEndReason)

    var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }

    /// The deadline of an armed mode; nil otherwise.
    var deadline: Date? {
        if case .armed(let deadline, _) = self { return deadline }
        return nil
    }
}

/// What could not be done. `Error` because it is `Result`'s failure in the client's
/// transport (review C6).
enum KeepAwakeFailure: Error, Codable, Equatable, Sendable {
    /// Daemon: a command (pmset) exited non-zero. App: osascript did, for the reset's prompt.
    case commandFailed(command: String, status: Int32)
    /// Daemon or app: the flag read back from `pmset -g` is not the value just applied.
    case readBack(expected: Bool)
    /// Daemon: a duration outside one minute to seven days.
    case invalidDuration
    /// App: the XPC connection failed before a reply arrived.
    case helperUnavailable(reason: String)
    /// App: no reply within the transport's timeout.
    case helperTimedOut
    /// App: the reply could not be decoded.
    case unreadableReply
    /// App: this build has no team, so there is no signing requirement to talk under.
    case notSigned
    /// App: `SMAppService.register()` failed and the helper is not registered.
    case registrationFailed(reason: String)
    /// App: `SMAppService.unregister()` failed during a reset.
    case unregisterFailed(reason: String)
    /// App: the administrator prompt of the reset was cancelled.
    case adminCancelled
    /// App: the helper stopped but pmset still reads `SleepDisabled 1` (review P1b).
    case flagStillSet
}

/// One XPC reply: the daemon's state after the call, and what it could not do.
struct KeepAwakeReply: Codable, Equatable, Sendable {
    var state: KeepAwakeState
    var failure: KeepAwakeFailure?
}

/// The JSON both sides of XPC and the state file speak: dates as seconds since 1970, keys
/// sorted. A fresh coder per call, so no coder is shared across the daemon's threads.
enum KeepAwakeCoding {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
