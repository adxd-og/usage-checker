import Foundation

/// The app's background children — agy runs and Claude Code's renewal start — running
/// now (spec 2026-10-16-antigravity-argon, Package 2 Design): a background run must not
/// outlive the app that started it, so Omelette stops them as it quits. A child is
/// registered before it starts and leaves when it exits; one that could not start leaves
/// at once.
/// `terminateAll()` closes the registry for good: no child starts after the quit.
final class ChildProcessRegistry: @unchecked Sendable {
    /// The app's registry; `AppDelegate.applicationWillTerminate` stops its children and
    /// closes it.
    static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    // Guarded by `lock`.
    private var children: [ObjectIdentifier: Process] = [:]
    private var closed = false

    /// Takes `process` in before it starts. False once `terminateAll()` has run: Omelette
    /// is quitting, and the child must not start.
    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        children[ObjectIdentifier(process)] = process
        return true
    }

    /// Called right after `process` started. `terminateAll()` signals only a running
    /// child, so one registered before it and started after it was passed by: it is
    /// stopped here, through `Process.terminate()`.
    func didStart(_ process: Process) {
        lock.lock()
        let quitting = closed
        lock.unlock()
        if quitting { process.terminate() }
    }

    func unregister(_ process: Process) {
        lock.lock()
        children[ObjectIdentifier(process)] = nil
        lock.unlock()
    }

    /// The children registered and not yet unregistered (their caller unregisters them
    /// after its own wait, so one that just exited may still count).
    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return children.count
    }

    /// SIGTERM, through `Process.terminate()`, to every registered child still running,
    /// and the registry closed: a later `register` is refused, and a child registered but
    /// not yet started is stopped by `didStart` once it is. Called as Omelette quits;
    /// nothing here waits for the children to go or sends SIGKILL: agy and Claude Code both
    /// end on SIGTERM, and a child that ignored it would run on until its caller's own
    /// deadline (`ClaudePTYStart.run` sends SIGKILL after its grace) or the app's exit.
    func terminateAll() {
        lock.lock()
        closed = true
        let running = Array(children.values)
        lock.unlock()
        for process in running where process.isRunning {
            process.terminate()
        }
    }
}
