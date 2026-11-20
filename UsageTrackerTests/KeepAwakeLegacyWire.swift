import Foundation
@testable import Omelette

/// Brioche 4.3.0's keep-awake types, as Swift synthesizes their JSON: what a build that predates
/// the thermal guard decodes (spec 2026-11-19 thermal guard, § Daemon). Copied from
/// `KeepAwakeCore/KeepAwakeState.swift` and `KeepAwakeStateFile.swift` at `2fa398b` and never
/// changed; `KeepAwakeFailure` is reused because the guard leaves it as it was.
enum KeepAwakeLegacy {
    enum EndReason: String, Codable, Equatable {
        case deadline, batteryFloor, cancelled, restarted, stopped
    }

    enum State: Codable, Equatable {
        case idle
        case armed(deadline: Date, floorEnabled: Bool)
        case ended(at: Date, reason: EndReason)
    }

    struct Reply: Codable, Equatable {
        var state: State
        var failure: KeepAwakeFailure?
    }

    struct Envelope: Codable, Equatable {
        var version: Int
        var state: State
        var failure: KeepAwakeFailure?
        var sleepOwed: Bool?
        var ownsFlag: Bool?
    }
}
