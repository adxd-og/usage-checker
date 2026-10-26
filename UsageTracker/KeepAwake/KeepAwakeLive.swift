import Foundation
import ServiceManagement

extension KeepAwakeClient.Dependencies {
    /// The real thing: `SMAppService` for the daemon's plist, XPC to its Mach service, the
    /// registered build in `UserDefaults`. `SMAppService` is built inside each closure; it is
    /// not Sendable.
    static var live: Self {
        Self(
            status: { SMAppService.daemon(plistName: KeepAwakeIdentity.plistName).status },
            register: { try SMAppService.daemon(plistName: KeepAwakeIdentity.plistName).register() },
            send: { await KeepAwakeXPCTransport.send($0) },
            unregister: { try await SMAppService.daemon(plistName: KeepAwakeIdentity.plistName).unregister() },
            readFlag: { await KeepAwakeLive.readFlag() },
            adminClear: { await KeepAwakeLive.adminClear() },
            registeredBuild: { UserDefaults.standard.string(forKey: KeepAwakeClient.registeredBuildKey) },
            setRegisteredBuild: { build in
                if let build {
                    UserDefaults.standard.set(build, forKey: KeepAwakeClient.registeredBuildKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: KeepAwakeClient.registeredBuildKey)
                }
            },
            currentBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        )
    }
}

/// The reset's two machine calls, off the caller's actor (as `TmuxJump.run` does).
enum KeepAwakeLive {
    /// `pmset -g` as the user: reading the flag needs no root.
    static func readFlag() async -> KeepAwakeFlagReading {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = KeepAwakeCommand.run(KeepAwakeCommand.pmset, ["-g"], timeout: 10)
                continuation.resume(returning: result.status == 0 ? KeepAwakeReadings.flag(fromPmset: result.output) : .unreadable)
            }
        }
    }

    /// One administrator prompt running `pmset -a disablesleep 0`. Five minutes: the user is
    /// typing a password.
    static func adminClear() async -> KeepAwakeFailure? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = KeepAwakeCommand.run(KeepAwakeCommand.osascript, ["-e", KeepAwakeClient.adminClearScript], timeout: 300)
                continuation.resume(returning: KeepAwakeClient.adminClearFailure(status: result.status, output: result.output))
            }
        }
    }
}

/// One XPC call per connection (plan D6): a privileged lookup of the daemon's Mach service,
/// a helper that must be signed by the app's own team (D3), ten seconds at most, then the
/// connection is invalidated.
enum KeepAwakeXPCTransport {
    static let timeout: TimeInterval = 10

    static func send(_ request: KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure> {
        guard let requirement = KeepAwakeSigning.helperRequirement(teamID: KeepAwakeSigning.ownTeamIdentifier()) else {
            return .failure(.notSigned)
        }
        let connection = NSXPCConnection(machServiceName: KeepAwakeIdentity.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: KeepAwakeXPCProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        let result: Result<KeepAwakeReply, KeepAwakeFailure> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(.helperTimedOut))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(.helperUnavailable(reason: error.localizedDescription)))
            } as? KeepAwakeXPCProtocol
            guard let proxy else {
                once.resume(.failure(.helperUnavailable(reason: "no proxy")))
                return
            }
            let reply: @Sendable (Data) -> Void = { data in
                if let decoded = KeepAwakeCoding.decode(KeepAwakeReply.self, from: data) {
                    once.resume(.success(decoded))
                } else {
                    once.resume(.failure(.unreadableReply))
                }
            }
            switch request {
            case .arm(let seconds, let floorEnabled):
                proxy.arm(seconds: seconds, floorEnabled: floorEnabled, withReply: reply)
            case .disarm:
                proxy.disarm(withReply: reply)
            case .setFloor(let enabled):
                proxy.setFloor(enabled: enabled, withReply: reply)
            case .state:
                proxy.state(withReply: reply)
            }
        }
        connection.invalidate()
        return result
    }
}

/// Resumes a continuation at most once: the reply, the error handler and the timeout race.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>?

    init(_ continuation: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<KeepAwakeReply, KeepAwakeFailure>) {
        let pending: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: result)
    }
}
