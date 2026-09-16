import AppKit

/// "Jump to session": put the window the agent is running in back in front of
/// the user. Best case that is the exact terminal tab; worst case it is the
/// project folder in Finder. Every failure is silent — a jump that doesn't work
/// must never interrupt anyone with an alert, and half a jump (the app is
/// frontmost, the tab is not) is still most of the value.
enum SessionActivator {
    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    /// A cmux tab's whole address. cmux exposes no tty and no per-tab pid, so this is
    /// the only way to name the tab a session is running in.
    struct CmuxTarget: Equatable {
        let workspace: String
        let surface: String
        let socketPath: String
    }

    /// A cmux session: the helper found both ids in the shell's environment. The
    /// bundle id alone is not enough — a cmux window whose environment carries no ids
    /// has nothing to address, and the app activation below is the whole jump there.
    static func cmuxTarget(for host: AgentHostInfo) -> CmuxTarget? {
        guard let workspace = host.cmuxWorkspace, !workspace.isEmpty,
              let surface = host.cmuxSurface, !surface.isEmpty
        else { return nil }
        let socket = host.cmuxSocket.flatMap { $0.isEmpty ? nil : $0 } ?? CmuxSocket.defaultPath
        return CmuxTarget(workspace: workspace, surface: surface, socketPath: socket)
    }

    /// A tmux pane's whole address, as the app uses it: the server's socket, the pane,
    /// and the tmux binary to run. Under tmux the helper reports no pid and no bundle
    /// id, so nothing else names the window this session is in.
    struct TmuxTarget: Equatable, Sendable {
        let socketPath: String
        let pane: String
        let binary: String
    }

    /// Where tmux is when the helper could not read the server's own path — the server
    /// had already gone, or the event came from an older helper. Homebrew first: that
    /// is where a tmux on this machine normally lives, and a GUI app's `PATH` has never
    /// heard of `/opt/homebrew/bin`.
    static let tmuxBinaryFallbacks = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// A tmux session: the helper found both the socket and the pane. A reported
    /// binary is taken as it stands — tmux was running when it was reported, and if it
    /// has been uninstalled since, the call simply fails and the click falls back to
    /// the Finder. Only the guesses are checked against the disk, and if none of them
    /// is there this is no target at all: running a binary we could not find is not a
    /// jump.
    static func tmuxTarget(
        for host: AgentHostInfo,
        binaryExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> TmuxTarget? {
        guard let socketPath = host.tmuxSocket, !socketPath.isEmpty,
              let pane = host.tmuxPane, !pane.isEmpty
        else { return nil }
        if let binary = host.tmuxBinary, !binary.isEmpty {
            return TmuxTarget(socketPath: socketPath, pane: pane, binary: binary)
        }
        guard let binary = tmuxBinaryFallbacks.first(where: binaryExists) else { return nil }
        return TmuxTarget(socketPath: socketPath, pane: pane, binary: binary)
    }

    /// Which of the four ways to bring a session back, decided before anything is
    /// activated so the choice itself is a test rather than a screenshot.
    ///
    /// The order is the whole rule. cmux wins because tmux started inside cmux
    /// inherits the `CMUX_*` ids into the tmux server's environment, so both addresses
    /// arrive — and only cmux can select its own tab. tmux wins over a pid because
    /// under tmux the pid is precisely the terminal the parent walk could not find.
    /// A pid wins over the project folder, which identifies nothing but the project.
    enum Route: Equatable {
        case cmux(CmuxTarget)
        case tmux(TmuxTarget)
        case process(pid: Int32)
        case finder
    }

    static func route(
        for host: AgentHostInfo,
        tmuxBinaryExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Route {
        if let target = cmuxTarget(for: host) { return .cmux(target) }
        if let target = tmuxTarget(for: host, binaryExists: tmuxBinaryExists) { return .tmux(target) }
        if let pid = host.pid { return .process(pid: pid) }
        return .finder
    }

    @MainActor
    static func jump(to session: AgentSession) {
        // cmux first: its socket is the only thing that can select the tab, and the
        // selection has to happen before the window comes forward or the user watches
        // the wrong tab appear and then swap.
        if let target = cmuxTarget(for: session.host) {
            CmuxSocket.send(
                lines: CmuxRPC.requests(workspace: target.workspace, surface: target.surface),
                to: target.socketPath
            )
            activate(pid: session.host.pid, bundleID: session.host.bundleID)
            return
        }
        if let pid = session.host.pid, let app = NSRunningApplication(processIdentifier: pid) {
            // macOS 14 activation model: hand Omelette's own activation to the
            // terminal — the user just clicked a row, so we are the active app and
            // may pass that on. (`.activateIgnoringOtherApps` is deprecated on 14.)
            app.activate(from: .current, options: [.activateAllWindows])
            if let bundleID = app.bundleIdentifier,
               let tty = session.host.tty, !tty.isEmpty,
               let source = script(for: bundleID, tty: tty) {
                run(source)
            }
            return
        }
        // No host process (passive scan, or the terminal has since quit): the
        // project folder is the only thing left that still identifies the session.
        guard let cwd = session.cwd, !cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    /// Bring the host app to the front: its own process when the pid is still valid,
    /// otherwise whichever running app carries that bundle id. Deliberately not
    /// `NSWorkspace.openApplication`, which would *launch* a terminal that has since
    /// quit — starting an empty cmux is not a jump to a session.
    @MainActor
    private static func activate(pid: Int32?, bundleID: String?) {
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(from: .current, options: [.activateAllWindows])
            return
        }
        guard let bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate(from: .current, options: [.activateAllWindows])
    }

    /// AppleScript that selects the tab/session whose tty matches, for the two
    /// terminals that expose a tty over Apple Events. nil for everything else —
    /// Ghostty, Warp, kitty, WezTerm, VS Code and Cursor have no such API, so
    /// activating the app is the whole jump there.
    ///
    /// `tell application id` addresses the app by bundle id: no guessing whether
    /// the user's copy is called "iTerm" or "iTerm2". `with timeout of 2 seconds`
    /// is what keeps a busy terminal from freezing our main thread — the default
    /// Apple Event timeout is two minutes.
    static func script(for bundleID: String, tty: String) -> String? {
        let tty = escapeForAppleScript(tty)
        switch bundleID {
        case terminalBundleID:
            return """
            with timeout of 2 seconds
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set frontmost of w to true
                                set selected of t to true
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            """
        case iTermBundleID:
            return """
            with timeout of 2 seconds
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end timeout
            """
        default:
            return nil
        }
    }

    /// An AppleScript string literal only needs these two characters escaped.
    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// NSAppleScript is documented as main-thread-only and the popover click that
    /// gets us here is already on the main actor. Errors are swallowed on purpose:
    /// denied automation (-1743), an app that quit (-600) and a tab that closed
    /// between the hook event and the click all mean the same thing to the user —
    /// the app is frontmost, the tab is wherever it is.
    @MainActor
    private static func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
