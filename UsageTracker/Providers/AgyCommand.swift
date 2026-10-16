import Foundation

/// Antigravity's own CLI, asked for the account's quota while the app is closed. Found and
/// started without a shell: a menu-bar app started by launchd does not inherit the login
/// shell's PATH.
enum AgyCommand {
    /// A run's answer is due by then. Measured runs took 5–24 s on 2026-10-16; the poll
    /// never waits for one (`AntigravityProvider.startAgyRunIfDue`), so the bound only ends
    /// a run that hangs.
    static let deadline: TimeInterval = 45
    /// SIGTERM at the deadline lets agy shut its store down cleanly; SIGKILL follows this
    /// much later if it is still there. Nobody waits for it.
    static let killGrace: TimeInterval = 5
    /// At most this much of agy's stdout is kept (1 MiB). Its answer is about 3 KB; a child
    /// that prints more is stopped, and the run is no reading.
    static let outputLimit = 1 << 20

    /// Runs `executable` with `arguments`, no shell, stdin and stderr closed, in `directory`,
    /// and returns its stdout when it exits 0. Throws `.launchFailed` when it cannot start,
    /// `.exitStatus` when it fails, `.outputTooLarge` once it has printed more than
    /// `outputLimit` (the child is stopped then), and `.timedOut` when it is still running,
    /// or its stdout still open, at `deadline`: the caller is answered then, the stdout
    /// reader is closed, the child gets SIGTERM, and SIGKILL `killGrace` later if it is
    /// still there.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        deadline: TimeInterval,
        killGrace: TimeInterval,
        outputLimit: Int = AgyCommand.outputLimit
    ) async throws -> Data {
        let child = AgyChild(
            executable: executable,
            arguments: arguments,
            environment: environment,
            directory: directory,
            outputLimit: outputLimit,
            killGrace: killGrace
        )
        return try await withCheckedThrowingContinuation { continuation in
            child.start(continuation, deadline: deadline)
        }
    }

    /// Where agy is, as the fleet finds it plus the installer's default: `AGY_BIN` (an
    /// absolute path, or one under `~/`), then `~/.local/bin/agy`, then each absolute PATH
    /// entry in order. The first candidate `isExecutable` accepts wins; nil when none does.
    /// A bare `AGY_BIN` name ("agy") is no path and is ignored; PATH covers it.
    static func executablePath(
        environment: [String: String],
        homeDirectory: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        var candidates: [String] = []
        if let bin = environment["AGY_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if bin.hasPrefix("/") {
                candidates.append(bin)
            } else if bin.hasPrefix("~/") {
                candidates.append(homeDirectory + String(bin.dropFirst()))
            }
        }
        candidates.append(homeDirectory + "/.local/bin/agy")
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where entry.hasPrefix("/") {
            candidates.append(entry.hasSuffix("/") ? entry + "agy" : entry + "/agy")
        }
        return candidates.first(where: isExecutable)
    }
}

/// One agy run: the child, its stdout, and the caller waiting on them. The end of the
/// output, the cap and the deadline race to answer the caller; the lock lets exactly one
/// of them do it, and every later answer is dropped.
///
/// stdout is read through a `DispatchIO` channel, so no thread ever blocks on it: closing
/// the channel cancels the pending read even while something the child left behind still
/// holds the pipe open, and the channel hands the descriptor back to be closed once.
private final class AgyChild: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let queue = DispatchQueue(label: "omelette.agy-run", qos: .utility)
    private let outputLimit: Int
    private let killGrace: TimeInterval
    private let lock = NSLock()
    // Guarded by `lock`.
    private var continuation: CheckedContinuation<Data, Error>?
    private var output = Data()
    private var reader: DispatchIO?
    private var outputEnded = false
    private var exited = false

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        outputLimit: Int,
        killGrace: TimeInterval
    ) {
        self.outputLimit = outputLimit
        self.killGrace = killGrace
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardOutput = stdout
        // Not read, so not a pipe: an unread pipe fills up and stalls the child.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }

    /// Starts the child, its reader and the deadline. `continuation` is answered once.
    func start(_ continuation: CheckedContinuation<Data, Error>, deadline: TimeInterval) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        process.terminationHandler = { [weak self] _ in
            self?.childExited()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            try? stdout.fileHandleForReading.close()
            settle(.failure(AgyUsageError.launchFailed(error.localizedDescription)))
            return
        }
        startReading()
        queue.asyncAfter(deadline: .now() + deadline) { [self] in
            if settle(.failure(AgyUsageError.timedOut)) { stop() }
        }
    }

    /// Reads stdout as it comes, in chunks of at most 64 KiB, until it ends or the channel
    /// is closed. A read that fails ends nothing; the deadline does.
    private func startReading() {
        let handle = stdout.fileHandleForReading
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            // The channel is done with the descriptor; its owner closes it, once.
            try? handle.close()
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 64 * 1024)
        lock.lock()
        reader = channel
        lock.unlock()
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
            if let data, !data.isEmpty { received(data) }
            if done, error == 0 { outputReachedEnd() }
        }
    }

    /// One chunk of stdout, kept while the total stays within `outputLimit`. Past it the
    /// caller is answered `.outputTooLarge` and the child is stopped; a chunk that comes
    /// after the answer is dropped.
    private func received(_ data: DispatchData) {
        lock.lock()
        let waiting = continuation != nil
        let overflows = waiting && output.count + data.count > outputLimit
        if waiting, !overflows {
            data.enumerateBytes { bytes, _, _ in output.append(bytes) }
        }
        lock.unlock()
        if overflows, settle(.failure(AgyUsageError.outputTooLarge)) { stop() }
    }

    private func outputReachedEnd() {
        lock.lock()
        outputEnded = true
        let channel = reader
        let childIsGone = exited
        lock.unlock()
        channel?.close()
        if childIsGone { finish() }
    }

    private func childExited() {
        lock.lock()
        exited = true
        let outputIsDone = outputEnded
        lock.unlock()
        if outputIsDone { finish() }
    }

    /// The child exited and its stdout ended: stdout when it exited 0 by itself, its
    /// status otherwise (a signal's number when one ended it).
    private func finish() {
        lock.lock()
        let data = output
        lock.unlock()
        if process.terminationReason == .exit, process.terminationStatus == 0 {
            settle(.success(data))
        } else {
            settle(.failure(AgyUsageError.exitStatus(process.terminationStatus)))
        }
    }

    /// Ends the run after the caller was answered `.timedOut` or `.outputTooLarge`: the
    /// stdout reader is closed first, so a read pending on a pipe that something the child
    /// left behind still holds open returns; then SIGTERM through `Process.terminate()`
    /// while the child runs, and SIGKILL `killGrace` later if it still runs. agy starts no
    /// process of its own (measured on 2026-10-16: no child during a run, its language
    /// server is in-process), so the signal reaches all of it.
    private func stop() {
        lock.lock()
        let channel = reader
        lock.unlock()
        channel?.close(flags: .stop)
        guard process.isRunning else { return }
        process.terminate()
        queue.asyncAfter(deadline: .now() + killGrace) { [self] in
            // Signalled only while `isRunning` says the pid is still this child's: a pid
            // is reused only after Foundation reaps the child, and `isRunning` turns false
            // right after the reap. The few instructions between the two, and between
            // this check and `kill`, are the residual pid-reuse window, accepted.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Answers the caller if nobody has yet. True when this call was the answer.
    @discardableResult
    private func settle(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return waiting != nil
    }
}
