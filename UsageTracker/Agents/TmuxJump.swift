import Foundation

/// The tmux half of "jump to session": ask the server which client is attached to the
/// pane's session, and point the most recently used one at the pane.
///
/// Everything here is best effort and silent. tmux not running, a session nobody is
/// attached to, a pane that has closed and a tmux that has been uninstalled all mean
/// the same thing to the user — the click falls back to the project folder, exactly
/// as it did before this existed.
///
/// The process runner is injected so no test ever spawns tmux; the default one gives
/// each call a second and throws away anything slower.
enum TmuxJump {
    /// One attached client: the process that runs inside the real terminal window, and
    /// the tty that terminal gave it. Not the pane's tty — that one belongs to the
    /// shell inside tmux and no terminal has ever heard of it.
    struct Client: Equatable, Sendable {
        let pid: Int32
        let tty: String
    }

    typealias Runner = @Sendable (_ binary: String, _ arguments: [String]) async -> String?

    /// Per-call budget. A wedged tmux server must not hold a click.
    static let timeout: TimeInterval = 1

    /// `#{client_activity}` is a unix timestamp, so the client the user touched last
    /// is the largest one. Tabs separate the fields: a tty never contains one.
    static let clientFormat = "#{client_pid}\t#{client_tty}\t#{client_activity}"

    /// `-S <socket>` is a *server* option and has to come before the command; tmux
    /// rejects it after `list-clients`. `-t` takes the pane id and resolves to the
    /// session that holds it.
    static func listClientsArguments(socketPath: String, pane: String) -> [String] {
        ["-S", socketPath, "list-clients", "-F", clientFormat, "-t", pane]
    }

    /// One call is enough: `switch-client` selects the session, the window and the
    /// pane for that client at once.
    static func switchClientArguments(socketPath: String, pane: String, clientTTY: String) -> [String] {
        ["-S", socketPath, "switch-client", "-c", clientTTY, "-t", pane]
    }

    /// The client that used this session last. nil when nothing is attached (the
    /// session is detached) or tmux answered with something we don't recognise. Ties
    /// go to the first line tmux printed — deterministic beats clever.
    static func pickClient(from output: String) -> Client? {
        var best: (client: Client, activity: Double)?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let pid = Int32(fields[0]), pid > 0,
                  let activity = Double(fields[2])
            else { continue }
            let tty = String(fields[1])
            guard !tty.isEmpty else { continue }
            if activity > (best?.activity ?? -.infinity) {
                best = (Client(pid: pid, tty: tty), activity)
            }
        }
        return best?.client
    }

    /// Ask which clients are attached, point the most recently used one at the pane,
    /// and hand it back so the caller can activate the terminal it runs inside. nil
    /// when there is nothing attached or tmux would not answer — the caller then falls
    /// back to the Finder.
    static func selectPane(
        _ target: SessionActivator.TmuxTarget,
        runner: Runner = TmuxJump.run
    ) async -> Client? {
        guard let output = await runner(
                  target.binary,
                  listClientsArguments(socketPath: target.socketPath, pane: target.pane)
              ),
              let client = pickClient(from: output)
        else { return nil }
        _ = await runner(
            target.binary,
            switchClientArguments(socketPath: target.socketPath, pane: target.pane, clientTTY: client.tty)
        )
        return client
    }

    /// stdout of `binary arguments`, off the main actor. nil when the binary cannot be
    /// started, took longer than `timeout`, or exited non-zero — tmux prints
    /// "can't find pane: %9" and exits 1 for a pane that has closed since the event.
    static func run(_ binary: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSynchronously(binary, arguments))
            }
        }
    }

    private static func runSynchronously(_ binary: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: waiting on a process whose pipe is full deadlocks.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
