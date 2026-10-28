import Darwin
import Foundation

/// Starts a program on a pseudo-terminal of its own, lets it run, and ends it, typing nothing
/// into it (spec 2026-10-25 § Design › Package 2, Renewal through Claude Code).
///
/// Claude Code renews an expired sign-in as it starts (verification (2), 2026-10-28), and its
/// full-screen interface wants a terminal, so this is all a renewal needs. Nothing is typed: a
/// keystroke could answer one of its first-run screens (a theme, the folder-trust question) and
/// change the user's Claude Code settings. The one thing written back is a terminal's answer
/// when the program asks where the cursor is, which a real terminal sends on its own.
enum ClaudePTYStart {
    enum Failure: Error, Equatable {
        /// No pseudo-terminal could be opened.
        case noTerminal
        /// The program would not start; the system's words.
        case launch(String)
    }

    /// "Where is the cursor?" (`ESC [ 6 n`) and a terminal's answer, top left (`ESC [ 1 ; 1 R`).
    static let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
    static let cursorReply = Data([0x1B, 0x5B, 0x31, 0x3B, 0x31, 0x52])

    /// Runs `binary` until it exits or `duration` has passed, then asks it to stop (SIGTERM)
    /// and, after `grace`, makes it (SIGKILL). The program is in `registry` from its start to
    /// its end, so Omelette quitting stops it (`applicationWillTerminate` → `terminateAll`);
    /// once the registry is closed nothing starts and the answer is `.launch`.
    static func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        duration: TimeInterval,
        grace: TimeInterval = 1,
        registry: ChildProcessRegistry = .shared
    ) async throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else { throw Failure.noTerminal }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        let primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        defer { try? primaryHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        // Registered before it starts, so a quit from here on reaches it.
        guard registry.register(process) else {
            try? secondaryHandle.close()
            throw Failure.launch("Omelette is quitting")
        }
        defer { registry.unregister(process) }
        do {
            try process.run()
        } catch {
            try? secondaryHandle.close()
            throw Failure.launch(error.localizedDescription)
        }
        // A quit between the registration and the start passed this program by.
        registry.didStart(process)
        // The child has its own copy; ours would keep the terminal open after it exits.
        try? secondaryHandle.close()

        let deadline = Date().addingTimeInterval(duration)
        var recent = Data()
        // A cancelled poll stops Claude Code at once: `Task.sleep` throws straight away once the
        // task is cancelled, and without this check the loop would spin until the deadline.
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            let output = readAvailable(primary)
            if !output.isEmpty {
                recent.append(output)
                if recent.range(of: cursorQuery) != nil {
                    write(cursorReply, to: primary)
                    recent.removeAll()
                } else if recent.count > cursorQuery.count {
                    recent = recent.suffix(cursorQuery.count - 1)
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard process.isRunning else { return }
        process.terminate()
        let killAt = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < killAt, !Task.isCancelled {
            _ = readAvailable(primary)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // A process stopped while its terminal holds unread output stays in the kernel's
        // exit until someone reads or closes that terminal (measured 2026-10-28: a driver
        // that stopped reading hung in waitpid for minutes, the CLI in state "E"). Close
        // ours before waiting; the defer's close is then a no-op.
        try? primaryHandle.close()
        // Not `waitUntilExit()`: called from a task it waits on a run loop nobody drives and can
        // miss the exit for good — measured 2026-10-28, 2 of 5 stress runs of 80 starts hung with
        // no child left, which would hold the renewal gate and Claude's poll until a relaunch.
        await waitForExit(process)
    }

    /// Waits for `process` to be gone, polling, for at most `limit`: past it the process is
    /// left to the system rather than the poll waiting on it.
    static func waitForExit(_ process: Process, limit: TimeInterval = 5) async {
        let giveUpAt = Date().addingTimeInterval(limit)
        while process.isRunning, Date() < giveUpAt {
            // A cancelled task's sleep returns at once; a short blocking pause keeps this a wait.
            if Task.isCancelled { usleep(20_000) } else { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
    }

    /// Everything the program has written since the last read; empty when nothing is waiting.
    private static func readAvailable(_ descriptor: Int32) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return output }
            output.append(contentsOf: buffer[0..<count])
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = Darwin.write(descriptor, base, bytes.count)
        }
    }
}
