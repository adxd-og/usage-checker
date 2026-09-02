import AppKit

/// Answers one question for the permission broker: is the user looking at the app
/// that hosts a session right now? "Looking at" means that app is frontmost and the
/// screen is neither locked nor asleep. Also reports every app activation so the
/// broker can release a hold the moment the user switches back to the terminal.
///
/// `frontmost` and `isLockedOrAsleep` are injectable so the rule is testable without
/// a window server; production reads `NSWorkspace` and tracks lock/sleep from the
/// same notifications `AppState.observeSystemState` uses. Both closures are
/// `@MainActor`: they are only ever called from `isUserAt`, and a main-actor type
/// lets the defaults (static members of this class) and test closures that read
/// main-actor state be passed without losing the actor.
@MainActor
final class PresenceMonitor {
    static let shared = PresenceMonitor()

    typealias Frontmost = (pid: Int32?, bundleID: String?)

    /// Every `NSWorkspace.didActivateApplicationNotification` after `start()`.
    var onActivation: ((NSRunningApplication) -> Void)?

    private let frontmost: @MainActor () -> Frontmost?
    private let lockedOrAsleepOverride: (@MainActor () -> Bool)?
    private var locked = false
    private var asleep = false
    private var observers: [NSObjectProtocol] = []

    init(
        frontmost: @escaping @MainActor () -> Frontmost? = PresenceMonitor.systemFrontmost,
        isLockedOrAsleep: (@MainActor () -> Bool)? = nil
    ) {
        self.frontmost = frontmost
        self.lockedOrAsleepOverride = isLockedOrAsleep
    }

    static func systemFrontmost() -> Frontmost? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.processIdentifier, app.bundleIdentifier)
    }

    var isLockedOrAsleep: Bool { lockedOrAsleepOverride?() ?? (locked || asleep) }

    /// Spec: frontmost app's pid == host.pid, or bundle id match when the host has no
    /// pid; false whenever the screen is locked or asleep.
    func isUserAt(host: AgentHostInfo) -> Bool {
        guard !isLockedOrAsleep else { return false }
        return Self.matches(frontmost: frontmost(), host: host)
    }

    /// The pure rule. A pid, when the host reported one, must match exactly — the
    /// bundle id is only consulted for hosts that came without a pid.
    static func matches(frontmost: Frontmost?, host: AgentHostInfo) -> Bool {
        guard let frontmost else { return false }
        if let pid = host.pid { return frontmost.pid == pid }
        if let bundleID = host.bundleID { return frontmost.bundleID == bundleID }
        return false
    }

    func setLocked(_ value: Bool) { locked = value }
    func setAsleep(_ value: Bool) { asleep = value }

    /// Registers the observers once. Observer blocks run on the main queue; the
    /// `@Sendable` closures capture only a weak self and, for activation, pull the
    /// app out of the notification *before* `assumeIsolated`: `Notification` is not
    /// Sendable and may not cross into the actor, `NSRunningApplication` is.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func flag(locked: Bool? = nil, asleep: Bool? = nil) -> @Sendable (Notification) -> Void {
            { [weak self] _ in
                MainActor.assumeIsolated {
                    if let locked { self?.setLocked(locked) }
                    if let asleep { self?.setAsleep(asleep) }
                }
            }
        }
        observers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.onActivation?(app) }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: flag(asleep: true)),
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: flag(asleep: false)),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: flag(asleep: true)),
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: flag(asleep: false)),
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: flag(locked: true)),
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: flag(locked: false)),
        ]
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        observers = []
    }
}
