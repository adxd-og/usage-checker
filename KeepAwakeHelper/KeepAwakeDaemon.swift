import Foundation

/// The exported object: each call hops onto the service's actor and replies with its JSON.
/// Captures the service, never `self` (an `NSObject` is not Sendable).
final class KeepAwakeXPCHandler: NSObject, KeepAwakeXPCProtocol {
    let service: KeepAwakeService

    init(service: KeepAwakeService) {
        self.service = service
    }

    func arm(seconds: Double, floorEnabled: Bool, withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = self.service
        Task {
            let result = await service.arm(seconds: seconds, floorEnabled: floorEnabled, now: Date())
            reply(KeepAwakeCoding.encode(result))
        }
    }

    func disarm(withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = self.service
        Task {
            let result = await service.disarm(now: Date())
            reply(KeepAwakeCoding.encode(result))
        }
    }

    func setFloor(enabled: Bool, withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = self.service
        Task {
            let result = await service.setFloor(enabled: enabled, now: Date())
            reply(KeepAwakeCoding.encode(result))
        }
    }

    func state(withReply reply: @escaping @Sendable (Data) -> Void) {
        let service = self.service
        Task {
            let result = await service.state(now: Date())
            reply(KeepAwakeCoding.encode(result))
        }
    }
}

/// The Mach service launchd hands the daemon. XPC checks every caller's signature against the
/// requirement before a message is delivered (plan D2); the service keeps the only count of
/// open connections (review C2).
final class KeepAwakeListener: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: KeepAwakeIdentity.machServiceName)
    private let service: KeepAwakeService

    init(service: KeepAwakeService) {
        self.service = service
    }

    /// Starts listening; false when this build has no team, and so no requirement to demand.
    func resume() -> Bool {
        guard let requirement = KeepAwakeSigning.callerRequirement(teamID: KeepAwakeSigning.ownTeamIdentifier()) else {
            return false
        }
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
        listener.resume()
        return true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: KeepAwakeXPCProtocol.self)
        newConnection.exportedObject = KeepAwakeXPCHandler(service: service)
        let service = self.service
        Task { await service.connectionOpened(now: Date()) }
        newConnection.invalidationHandler = {
            Task { await service.connectionClosed(now: Date()) }
        }
        newConnection.resume()
        return true
    }
}

/// omelette-keepawake's life, in order: the service and its timers; the stop path (SIGTERM,
/// SIGINT) before anything else, so a signal during the start is not lost; the start, which
/// clears the flag, before listening; power notifications; the listener; then the run loop.
/// The ways out are the idle exit and the stop path (status 0 from inside the actor, not
/// restarted; status 1 when a stop could not clear, so launchd restarts it) and a crash
/// (restarted by `KeepAlive`, whose start clears).
enum KeepAwakeDaemon {
    static func run() -> Never {
        // 1. The service and its two wall-clock timers.
        let scheduler = WallClockScheduler(label: "com.usagetracker.app.keepawake.tick")
        let exitScheduler = WallClockScheduler(label: "com.usagetracker.app.keepawake.exit")
        let service = KeepAwakeService(
            machine: LiveMachine.make(scheduler: scheduler, exitScheduler: exitScheduler),
            stateFile: KeepAwakeStateFile(url: KeepAwakeIdentity.stateFileURL)
        )
        scheduler.onFire = { Task { _ = await service.tick(now: Date()) } }
        // The actor decides and exits in one step; nothing is checked out here (review C2).
        exitScheduler.onFire = { Task { await service.exitIfIdle(now: Date()) } }

        // 2. The stop path (review C3): launchd's SIGTERM clears an armed flag before exiting.
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { Task { await service.terminate(now: Date()) } }
            source.resume()
            signalSources.append(source)
        }

        // 3. Start before listening: the flag is cleared before any caller can arm.
        let started = DispatchSemaphore(value: 0)
        Task {
            let reply = await service.start(now: Date())
            NSLog("[keepawake] start: %@", String(describing: reply))
            started.signal()
        }
        started.wait()

        // 4. Battery changes.
        let power = PowerObserver { Task { _ = await service.powerChanged(now: Date()) } }
        power.install()

        // 5. The listener. Without a team nothing can connect, and the daemon exits idle a
        // minute after its start.
        let listener = KeepAwakeListener(service: service)
        if !listener.resume() {
            NSLog("[keepawake] not signed by a team: not listening")
        }

        // 6. A timer, so the run loop cannot return by itself on a Mac without an IOPS source.
        let keepAlive = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in }

        // 7. Run.
        withExtendedLifetime((scheduler, exitScheduler, signalSources, power, listener, keepAlive)) {
            RunLoop.main.run()
        }
        exit(0)
    }
}
