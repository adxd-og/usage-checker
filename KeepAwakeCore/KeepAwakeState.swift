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
    /// The thermal guard (spec 2026-11-19): the Mac overheated with the lid closed.
    case overheated

    /// The reason written under `reason` for a build that predates this one; the real one goes
    /// beside it under `cause` (`KeepAwakeState`'s JSON; spec 2026-11-19 thermal guard, § Plan
    /// decisions accepted by the session, item 4). Every reason 4.3.0 knows is written as
    /// itself; a new reason names the one that reads least wrong.
    var olderBuildsRead: KeepAwakeEndReason {
        switch self {
        case .deadline, .batteryFloor, .cancelled, .restarted, .stopped:
            return self
        // "the helper was stopped": the mode is over, and it claims no time and no battery.
        case .overheated:
            return .stopped
        }
    }
}

/// What the daemon reports and persists; the app mirrors it.
///
/// Its JSON is the one Swift synthesized up to 4.3.0 — `{"idle":{}}`,
/// `{"armed":{"deadline":…,"floorEnabled":…}}`, `{"ended":{"at":…,"reason":…}}` — written by
/// hand since the thermal guard, so an end reason older builds do not know travels as one they
/// do (`KeepAwakeEndReason.olderBuildsRead`) with the real one beside it under `cause`. An
/// `ended` state reads whenever its `at` does: a `reason` that is missing, not a string or not
/// known reads as `stopped`, and a known `cause` wins, so the file never loses the helper's
/// claim on the flag over one field (spec § Accepted risks). Keys a build does not know are
/// skipped; a state whose key is not one of these three does not read, as before, which is why
/// a new way to end is a new reason and never a new state.
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

    private enum CodingKeys: String, CodingKey {
        case idle, armed, ended
    }

    private enum ArmedCodingKeys: String, CodingKey {
        case deadline, floorEnabled
    }

    private enum EndedCodingKeys: String, CodingKey {
        case at, reason, cause
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.typeMismatch(
                KeepAwakeState.self,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Invalid number of keys found, expected one.")
            )
        }
        switch key {
        case .idle:
            _ = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .idle)
            self = .idle
        case .armed:
            let armed = try container.nestedContainer(keyedBy: ArmedCodingKeys.self, forKey: .armed)
            self = .armed(
                deadline: try armed.decode(Date.self, forKey: .deadline),
                floorEnabled: try armed.decode(Bool.self, forKey: .floorEnabled)
            )
        case .ended:
            let ended = try container.nestedContainer(keyedBy: EndedCodingKeys.self, forKey: .ended)
            let at = try ended.decode(Date.self, forKey: .at)
            // Missing, not a string, or a reason this build does not know: an end all the same.
            let written = (try? ended.decodeIfPresent(String.self, forKey: .reason)).flatMap(KeepAwakeEndReason.init(rawValue:))
            // A cause this build does not know (a later build's reason) falls back to `reason`.
            let cause = (try? ended.decodeIfPresent(String.self, forKey: .cause)).flatMap(KeepAwakeEndReason.init(rawValue:))
            self = .ended(at: at, reason: cause ?? written ?? .stopped)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            _ = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .idle)
        case .armed(let deadline, let floorEnabled):
            var armed = container.nestedContainer(keyedBy: ArmedCodingKeys.self, forKey: .armed)
            try armed.encode(deadline, forKey: .deadline)
            try armed.encode(floorEnabled, forKey: .floorEnabled)
        case .ended(let at, let reason):
            var ended = container.nestedContainer(keyedBy: EndedCodingKeys.self, forKey: .ended)
            try ended.encode(at, forKey: .at)
            try ended.encode(reason.olderBuildsRead, forKey: .reason)
            if reason.olderBuildsRead != reason {
                try ended.encode(reason, forKey: .cause)
            }
        }
    }
}

/// What could not be done. `Error` because it is `Result`'s failure in the client's
/// transport (review C6).
enum KeepAwakeFailure: Error, Codable, Equatable, Sendable {
    /// Daemon: a command (pmset) exited non-zero. App: osascript did, for the reset's prompt.
    case commandFailed(command: String, status: Int32)
    /// Daemon or app: the flag read back from `pmset -g` is not the value just applied.
    case readBack(expected: Bool)
    /// Daemon: a duration outside one minute to 7 d 23 h 59 min.
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

/// One XPC reply: the daemon's state after the call, and what it could not do. Since the
/// thermal guard (spec 2026-11-19, § Daemon) it also carries the thermal level as the daemon
/// read it when it answered, and whether its guard is on. Both are absent from a daemon that
/// predates the guard, which is how the app knows not to ask it `setThermalGuard`; both are
/// encoded only when present, so a reply without them has 4.3.0's bytes, and a build that
/// predates them skips the two keys. A value of either that this build cannot read (a level it
/// does not know, anything that is not a string there or not a JSON boolean for the guard,
/// `null`) reads as absent, never as an unreadable reply.
struct KeepAwakeReply: Codable, Equatable, Sendable {
    var state: KeepAwakeState
    var failure: KeepAwakeFailure?
    var thermal: KeepAwakeThermalLevel? = nil
    var thermalGuard: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case state, failure, thermal, thermalGuard
    }
}

extension KeepAwakeReply {
    /// In an extension, so the memberwise initialiser stays (`KeepAwakeReply(state:failure:)`
    /// everywhere); `encode(to:)` stays synthesized and writes the optionals only when present.
    /// `state` and `failure` read as they always have: a state or a failure this build cannot
    /// read still fails the reply.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(KeepAwakeState.self, forKey: .state)
        failure = try container.decodeIfPresent(KeepAwakeFailure.self, forKey: .failure)
        thermal = try? container.decodeIfPresent(KeepAwakeThermalLevel.self, forKey: .thermal)
        thermalGuard = try? container.decodeIfPresent(Bool.self, forKey: .thermalGuard)
    }
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
