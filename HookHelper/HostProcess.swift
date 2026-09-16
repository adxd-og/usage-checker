import Foundation

/// What the envelope's `host` object says about the terminal / IDE this hook runs
/// under. The process tree is walked by `HostWalk` — a file the app compiles too,
/// because the app repeats the same walk on a tmux client's pid. What stays here is
/// what is genuinely hook-shaped: the field names that go on the wire, and the
/// addresses that are read out of the shell's environment rather than the tree.
struct HostProcess {
    var pid: Int32?
    var bundleID: String?
    var tty: String?
    /// cmux's own addressing, read out of the shell's environment rather than the
    /// process tree: `cmux → /usr/bin/login → zsh → claude` gives us a pid and a tty
    /// that cmux itself cannot do anything with.
    var cmuxWorkspace: String?
    var cmuxSurface: String?
    var cmuxSocket: String?
    /// tmux only, and read out of the environment for the same reason cmux is: the
    /// process tree cannot answer here at all. The pane's shell hangs off the tmux
    /// server, a daemon under launchd, so the walk above ends with no pid and no
    /// bundle id and the tty it reports is the pane's, not the terminal's.
    var tmux: TmuxAddress?
    /// `proc_pidpath` of the tmux server. nil when the pid is already gone; the app
    /// then falls back to tmux's usual install paths.
    var tmuxBinary: String?

    static let workspaceEnvironmentKey = "CMUX_WORKSPACE_ID"
    static let surfaceEnvironmentKey = "CMUX_SURFACE_ID"
    static let socketEnvironmentKey = "CMUX_SOCKET_PATH"

    /// `environment` is injectable for the tests; production reads our own, which is
    /// the shell's, which is cmux's when cmux started it.
    static func describe(
        from pid: pid_t = getpid(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostProcess {
        var result = HostProcess()
        let terminal = HostWalk.describe(from: pid)
        result.pid = terminal.pid
        result.bundleID = terminal.bundleID
        result.tty = terminal.tty
        result.cmuxWorkspace = nonEmpty(environment[workspaceEnvironmentKey])
        result.cmuxSurface = nonEmpty(environment[surfaceEnvironmentKey])
        result.cmuxSocket = nonEmpty(environment[socketEnvironmentKey])
        result.tmux = TmuxAddress.parse(environment: environment)
        result.tmuxBinary = result.tmux.flatMap { ProcessRecord.executablePath($0.serverPID) }
        return result
    }

    /// An exported-but-empty variable says as little as an unset one.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
