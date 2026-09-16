import Foundation

/// How a tmux pane is addressed from outside: the server's socket, the server's pid
/// (only ever used to read back the tmux binary that runs it) and the pane id.
///
/// tmux exports `TMUX=<socket path>,<server pid>,<session index>` and
/// `TMUX_PANE=%<n>` into every shell it starts, and `omelette-hook` inherits both —
/// which is the whole reason a jump is possible at all. The parent walk cannot find
/// the terminal under tmux: the pane's shell hangs off the tmux server, a daemon
/// under launchd, so the chain ends at pid 1 with no app on it.
///
/// Compiled into the app *and* the `OmeletteHook` target (one `- path:` entry per
/// target in project.yml), so the helper that writes the address and the app that
/// jumps with it cannot disagree about what a well-formed one is.
struct TmuxAddress: Equatable, Sendable {
    /// First field of `$TMUX`: an absolute path, e.g. `/private/tmp/tmux-501/default`.
    let socketPath: String
    /// Second field of `$TMUX`. `proc_pidpath` on it is where the tmux binary comes
    /// from — Homebrew's path is not on a GUI app's `PATH`.
    let serverPID: Int32
    /// `$TMUX_PANE`, always `%<digits>`.
    let pane: String

    static let environmentKey = "TMUX"
    static let paneEnvironmentKey = "TMUX_PANE"

    /// nil unless both variables are there and well-formed. Half an address is
    /// nothing to jump to, and a pane id we did not recognise must never be pasted
    /// into a tmux command line.
    static func parse(environment: [String: String]) -> TmuxAddress? {
        guard let raw = environment[environmentKey], !raw.isEmpty,
              let pane = environment[paneEnvironmentKey], isPaneID(pane)
        else { return nil }
        let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        let socketPath = String(fields[0])
        guard !socketPath.isEmpty, let serverPID = Int32(fields[1]), serverPID > 0 else { return nil }
        return TmuxAddress(socketPath: socketPath, serverPID: serverPID, pane: pane)
    }

    /// `%` followed by at least one ASCII digit and nothing else. Arabic-Indic digits
    /// satisfy `isNumber` and would reach tmux as a pane that does not exist, so the
    /// check is explicitly ASCII.
    static func isPaneID(_ value: String) -> Bool {
        guard value.hasPrefix("%") else { return false }
        let digits = value.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
