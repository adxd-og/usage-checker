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

/// The app's side of the helper (spec 2026-10-26, § Helper › App side): registers the daemon
/// on first use, maps `SMAppService`'s status, and calls the XPC methods.
///
/// Dependencies, each a closure so tests never reach launchd or XPC:
/// - `status`: `SMAppService.daemon(plistName:).status`.
/// - `register`: `SMAppService.daemon(plistName:).register()`.
/// - `send`: one XPC call over its own connection (`KeepAwakeXPCTransport`).
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
