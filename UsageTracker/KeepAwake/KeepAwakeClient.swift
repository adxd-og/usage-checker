import Foundation
import ServiceManagement

/// The helper's registration as the app sees it (`SMAppService.Status`, folded to three).
enum KeepAwakeRegistration: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case ready
}

/// One XPC call to the helper.
enum KeepAwakeRequest: Equatable, Sendable {
    case arm(seconds: TimeInterval, floorEnabled: Bool)
    case disarm
    case setFloor(enabled: Bool)
    case state
}

/// What a call came back with.
struct KeepAwakeOutcome: Equatable, Sendable {
    var registration: KeepAwakeRegistration
    /// nil: the helper was not asked, or did not answer.
    var state: KeepAwakeState?
    var failure: KeepAwakeFailure?
}

/// What a reset came back with (plan D13).
struct KeepAwakeResetOutcome: Equatable, Sendable {
    var registration: KeepAwakeRegistration
    var flag: KeepAwakeFlagReading
    var failure: KeepAwakeFailure?

    /// The Mac is back to normal: the flag reads clear and no helper is registered.
    var isComplete: Bool { flag.isClear && registration == .notRegistered }
}

/// The app's side of the helper (spec 2026-10-26, § Helper › App side): registers the daemon
/// on first use, maps `SMAppService`'s status, and calls the XPC methods.
///
/// Dependencies, each a closure so tests never reach launchd or XPC:
/// - `status`: `SMAppService.daemon(plistName:).status`.
/// - `register`: `SMAppService.daemon(plistName:).register()`.
/// - `send`: one XPC call over its own connection (`KeepAwakeXPCTransport`).
/// - `unregister`: `SMAppService.daemon(plistName:).unregister()`.
/// - `readFlag`: `pmset -g` as the user (no root needed), parsed.
/// - `adminClear`: `pmset -a disablesleep 0` through one `osascript … with administrator
///   privileges` prompt, the reset's way out when the helper cannot clear the flag.
/// - `registeredBuild` / `setRegisteredBuild`: the build that last registered, in `UserDefaults`.
/// - `currentBuild`: this bundle's `CFBundleVersion`.
///
/// Re-registering after an update (plan D12): the first Apply under a new build calls
/// `register()` again so launchd sees the new binary. Re-registering an enabled service
/// returns `kSMErrorAlreadyRegistered`; that error is ignored while the status stays enabled.
actor KeepAwakeClient {
    struct Dependencies: Sendable {
        var status: @Sendable () -> SMAppService.Status
        var register: @Sendable () throws -> Void
        var send: @Sendable (KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure>
        var unregister: @Sendable () async throws -> Void
        var readFlag: @Sendable () async -> KeepAwakeFlagReading
        /// One administrator prompt running `pmset -a disablesleep 0`; nil = it ran.
        var adminClear: @Sendable () async -> KeepAwakeFailure?
        var registeredBuild: @Sendable () -> String?
        var setRegisteredBuild: @Sendable (String?) -> Void
        var currentBuild: String
    }

    static let registeredBuildKey = "keepAwakeRegisteredBuild"
    /// The reason given when `register()` threw nothing yet the helper is still not registered.
    static let silentRegistrationReason = "macOS did not register it"

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func registration(from status: SMAppService.Status) -> KeepAwakeRegistration {
        switch status {
        case .enabled: return .ready
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// First use, or the first use under a new build.
    static func needsRegister(_ registration: KeepAwakeRegistration, registeredBuild: String?, currentBuild: String) -> Bool {
        registration == .notRegistered || (registration == .ready && registeredBuild != currentBuild)
    }

    func registration() -> KeepAwakeRegistration {
        Self.registration(from: dependencies.status())
    }

    /// Apply: registers the helper when needed, then arms it once it is approved.
    func arm(seconds: TimeInterval, floorEnabled: Bool) async -> KeepAwakeOutcome {
        var current = registration()
        var registerError: String?
        if Self.needsRegister(current, registeredBuild: dependencies.registeredBuild(), currentBuild: dependencies.currentBuild) {
            do {
                try dependencies.register()
            } catch {
                registerError = error.localizedDescription
            }
            current = registration()
            if current == .ready || current == .requiresApproval {
                dependencies.setRegisteredBuild(dependencies.currentBuild)
            }
        }
        switch current {
        case .requiresApproval:
            return KeepAwakeOutcome(registration: .requiresApproval, state: nil, failure: nil)
        case .notRegistered:
            return KeepAwakeOutcome(
                registration: .notRegistered,
                state: nil,
                failure: .registrationFailed(reason: registerError ?? Self.silentRegistrationReason)
            )
        case .ready:
            return await call(.arm(seconds: seconds, floorEnabled: floorEnabled))
        }
    }

    /// Cancel; a helper that is not ready has nothing to end.
    func disarm() async -> KeepAwakeOutcome {
        await callIfReady(.disarm)
    }

    /// The floor switch, for an armed helper.
    func setFloor(enabled: Bool) async -> KeepAwakeOutcome {
        await callIfReady(.setFloor(enabled: enabled))
    }

    /// What the helper says; never contacts one that is not ready.
    func state() async -> KeepAwakeOutcome {
        await callIfReady(.state)
    }

    /// The sleep flag as `pmset -g` reads it, as the user.
    func readFlag() async -> KeepAwakeFlagReading {
        await dependencies.readFlag()
    }

    /// The administrator prompt's script: pmset as root, nothing else.
    static let adminClearScript = #"do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges"#

    /// What osascript's exit says: 0 ran, `(-128)` is a cancelled prompt, anything else failed.
    static func adminClearFailure(status: Int32, output: String) -> KeepAwakeFailure? {
        guard status != 0 else { return nil }
        if output.contains("(-128)") { return .adminCancelled }
        return .commandFailed(command: "osascript", status: status)
    }

    /// Reset keep awake (spec 2026-10-26, § UI; plan D13; review C1): puts the Mac back the way
    /// it was before the feature.
    /// 1. A ready helper is disarmed; its failure does not stop the reset.
    /// 2. The flag is read as the user; only when it reads `SleepDisabled 1` does one
    ///    administrator prompt clear it, and the flag is read again.
    /// 3. Only once the flag reads clear is the helper unregistered (unless it never was) and
    ///    its build forgotten. A flag still set, or unreadable, keeps the helper registered: it
    ///    clears a flag it owns at its next start, and Reset can be pressed again.
    func reset() async -> KeepAwakeResetOutcome {
        let before = registration()
        if before == .ready {
            _ = await call(.disarm)
        }
        var flag = await readFlag()
        var adminFailure: KeepAwakeFailure?
        if flag == .set {
            adminFailure = await dependencies.adminClear()
            flag = await readFlag()
            if adminFailure == nil && flag == .set {
                adminFailure = .readBack(expected: false)
            }
        }
        var unregisterFailure: KeepAwakeFailure?
        if flag.isClear {
            if before != .notRegistered {
                do {
                    try await dependencies.unregister()
                } catch {
                    unregisterFailure = .unregisterFailed(reason: error.localizedDescription)
                }
            }
            if unregisterFailure == nil {
                dependencies.setRegisteredBuild(nil)
            }
        }
        return KeepAwakeResetOutcome(
            registration: (flag.isClear && unregisterFailure == nil) ? .notRegistered : registration(),
            flag: flag,
            failure: adminFailure ?? unregisterFailure
        )
    }

    private func callIfReady(_ request: KeepAwakeRequest) async -> KeepAwakeOutcome {
        let current = registration()
        guard current == .ready else {
            return KeepAwakeOutcome(registration: current, state: nil, failure: nil)
        }
        return await call(request)
    }

    private func call(_ request: KeepAwakeRequest) async -> KeepAwakeOutcome {
        switch await dependencies.send(request) {
        case .success(let reply):
            return KeepAwakeOutcome(registration: .ready, state: reply.state, failure: reply.failure)
        case .failure(let failure):
            return KeepAwakeOutcome(registration: .ready, state: nil, failure: failure)
        }
    }
}
