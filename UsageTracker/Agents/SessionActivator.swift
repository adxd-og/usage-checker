import AppKit

/// "Jump to session": put the window the agent is running in back in front of
/// the user. Best case that is the exact terminal tab; worst case it is the
/// project folder in Finder. Every failure is silent — a jump that doesn't work
/// must never interrupt anyone with an alert, and half a jump (the app is
/// frontmost, the tab is not) is still most of the value.
enum SessionActivator {
    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    @MainActor
    static func jump(to session: AgentSession) {
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
