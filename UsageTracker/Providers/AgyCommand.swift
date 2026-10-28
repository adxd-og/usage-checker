import Foundation

/// Antigravity's own CLI, asked for the account's quota while the app is closed. Found and
/// started without a shell: a menu-bar app started by launchd does not inherit the login
/// shell's PATH.
enum AgyCommand {
    /// `agy --log-file <logFile> -p /usage --output-format json`: the quota as one JSON
    /// object, no model turn. Without `--log-file` every run leaves a new
    /// `~/.gemini/antigravity-cli/log/cli-<time>.log` (about 29 KB) that agy never prunes,
    /// and points agy's `cli.log` link at it; with it, agy writes only `logFile`, starts it
    /// over on each run, and leaves its log folder and the link alone (measured on
    /// 2026-10-17). No `--print-timeout`: it does not bound `/usage` (measured), the
    /// deadline does.
    static func arguments(logFile: URL) -> [String] {
        ["--log-file", logFile.path, "-p", "/usage", "--output-format", "json"]
    }
    /// The file agy logs a run to, in the log folder `fetch` is given.
    static let logFileName = "agy-usage.log"
    /// Omelette's own Application Support folder, the one `HistoryStore` and the status
    /// file use: where agy's log goes unless a test says otherwise.
    static var defaultLogDirectory: URL { AgentPaths.appSupportURL }
    /// The variables agy gets from Omelette's environment, when set there.
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
    /// agy's PATH before its own folder: the system's folders only.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Set for the child only. With it agy runs no child process (measured on 2026-10-16);
    /// without it, agy would start its self-updater, a second process, on every run, and a
    /// background poll has no business updating the CLI.
    static let environmentOverrides = ["AGY_CLI_DISABLE_AUTO_UPDATE": "true"]
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

    /// agy's answer to `/usage`. agy is the one `executablePath` finds; it runs in
    /// `directory` (the user's temporary folder: agy writes nothing there, and one fixed
    /// folder is one workspace in agy's records) with `childEnvironment`. Throws
    /// `.notInstalled` without agy. agy reads its sign-in from the login keychain on every
    /// run, and a locked keychain answers with a password panel that a background poll
    /// must never raise (`KeychainNoUI`), so agy starts only while `keychainState` says
    /// unlocked: `.keychainLocked`, or `.keychainStateUnknown` when the state could not be
    /// read, and agy is not started. agy logs to `logFileName` in `logDirectory`, made
    /// when missing just before agy starts.
    static func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        keychainState: () -> KeychainNoUI.LockState = { KeychainNoUI.defaultKeychainLockState },
        directory: URL = FileManager.default.temporaryDirectory,
        logDirectory: URL = AgyCommand.defaultLogDirectory
    ) async throws -> Data {
        guard let path = executablePath(
            environment: environment,
            homeDirectory: homeDirectory,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else {
            throw AgyUsageError.notInstalled
        }
        switch keychainState() {
        case .unlocked: break
        case .locked: throw AgyUsageError.keychainLocked
        case .unknown: throw AgyUsageError.keychainStateUnknown
        }
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        return try await run(
            executable: path,
            arguments: arguments(logFile: logDirectory.appendingPathComponent(logFileName)),
            environment: childEnvironment(from: environment, executable: path, homeDirectory: homeDirectory),
            directory: directory,
            deadline: deadline,
            killGrace: killGrace
        )
    }

    /// The environment agy runs with, an allowlist: `inheritedVariables` from `environment`
    /// when set there (HOME falls back to `homeDirectory`: agy keeps its state under it),
    /// PATH as `systemPath` plus the folder agy is in, and `environmentOverrides`. Nothing
    /// else of Omelette's environment reaches agy: no token, proxy or `DYLD_` variable,
    /// nothing a parent shell exported.
    static func childEnvironment(
        from environment: [String: String],
        executable: String,
        homeDirectory: String
    ) -> [String: String] {
        var child: [String: String] = [:]
        for name in inheritedVariables {
            if let value = environment[name], !value.isEmpty { child[name] = value }
        }
        if child["HOME"] == nil { child["HOME"] = homeDirectory }
        let agyFolder = (executable as NSString).deletingLastPathComponent
        let systemFolders = systemPath.split(separator: ":").map(String.init)
        child["PATH"] = agyFolder.isEmpty || systemFolders.contains(agyFolder)
            ? systemPath
            : systemPath + ":" + agyFolder
        return child.merging(environmentOverrides) { _, override in override }
    }

    /// Runs `executable` with `arguments`, no shell, stdin and stderr closed, in `directory`,
    /// and returns its stdout when it exits 0. Throws `.launchFailed` when it cannot start,
    /// `.exitStatus` when it fails, `.outputTooLarge` once it has printed more than
    /// `outputLimit` (the child is stopped then), and `.timedOut` when it is still running,
    /// or its stdout still open, at `deadline`: the caller is answered then, the stdout
    /// reader is closed, the child gets SIGTERM, and SIGKILL `killGrace` later if it is
    /// still there. The child is in `registry` from its start to its exit, so quitting
    /// Omelette stops it; once the registry is closed (`terminateAll()`), no child starts
    /// and the answer is `.launchFailed`.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        deadline: TimeInterval,
        killGrace: TimeInterval,
        outputLimit: Int = AgyCommand.outputLimit,
        registry: ChildProcessRegistry = .shared
    ) async throws -> Data {
        let child = AgyChild(
            executable: executable,
            arguments: arguments,
            environment: environment,
            directory: directory,
            outputLimit: outputLimit,
            killGrace: killGrace,
            registry: registry
        )
        return try await withCheckedThrowingContinuation { continuation in
            child.start(continuation, deadline: deadline)
        }
    }

    /// Where agy is, as the fleet finds it plus the installer's default: `AGY_BIN` (an
    /// absolute path, or one under `~/`), then `~/.local/bin/agy`, then each absolute PATH
    /// entry in order. The first candidate `isExecutable` accepts wins; nil when none does.
    /// A bare `AGY_BIN` name ("agy-beta") is resolved as the fleet's `locateBin` resolves
    /// it: in the absolute PATH entries, in order, and nowhere else; when none holds it
    /// there is no agy. A relative entry never answers: the child runs elsewhere.
    static func executablePath(
        environment: [String: String],
        homeDirectory: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        func onPath(_ name: String) -> [String] {
            pathEntries.map { $0.hasSuffix("/") ? $0 + name : $0 + "/" + name }
        }
        let bin = environment["AGY_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !bin.isEmpty, !bin.contains("/") {
            return onPath(bin).first(where: isExecutable)
        }
        var candidates: [String] = []
        if bin.hasPrefix("/") {
            candidates.append(bin)
        } else if bin.hasPrefix("~/") {
            candidates.append(homeDirectory + String(bin.dropFirst()))
        }
        candidates.append(homeDirectory + "/.local/bin/agy")
        candidates += onPath("agy")
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
    private let registry: ChildProcessRegistry
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
        killGrace: TimeInterval,
        registry: ChildProcessRegistry
    ) {
        self.outputLimit = outputLimit
        self.killGrace = killGrace
        self.registry = registry
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
        process.terminationHandler = { [weak self, registry] exited in
            registry.unregister(exited)
            self?.childExited()
        }
        // Registered before it starts, so no exit can come before the registration.
        guard registry.register(process) else {
            process.terminationHandler = nil
            try? stdout.fileHandleForReading.close()
            settle(.failure(AgyUsageError.launchFailed("Omelette is quitting")))
            return
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            registry.unregister(process)
            try? stdout.fileHandleForReading.close()
            settle(.failure(AgyUsageError.launchFailed(error.localizedDescription)))
            return
        }
        // A quit between the registration and the start passed this child by.
        registry.didStart(process)
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
    /// while the child runs, and SIGKILL `killGrace` later if it still runs. With its
    /// self-updater off (`environmentOverrides`) agy runs no child process (measured on
    /// 2026-10-16: none during a run, its language server is in-process), so the signal
    /// reaches all of it.
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
