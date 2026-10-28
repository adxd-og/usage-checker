import AppKit
import Foundation

/// Sign in (spec 2026-10-25 § Design › Package 2): Terminal runs `<claude> auth login`, Claude
/// Code's own sign-in, from a `.command` file Omelette writes and hands to Terminal. Not through
/// Apple events: `SessionActivator.run` swallows a refused automation by design, and this button
/// must never do nothing — every way it can fail comes back as words.
enum ClaudeSignInLauncher {
    /// In Omelette's Application Support folder, rewritten on every click.
    static let fileName = "claude-sign-in.command"

    enum Outcome: Equatable, Sendable {
        case opened
        case failed(String)
    }

    /// The script. Terminal runs the user's shell startup files before it, so the clean
    /// environment is made here, at the invocation: every `ANTHROPIC_*` variable and the named
    /// ones unset in the shell itself, then Claude Code in place of the script. Not
    /// `env -u … <binary>`: `env` takes any word holding "=" for an assignment, so a `claude`
    /// under a folder like "a=b" would never run (tester, 2026-10-28).
    static func commandFile(binary: String) -> String {
        let prefix = ClaudeCLIEnvironment.scrubbedPrefix
        return """
        #!/bin/sh
        # Written by Omelette: Claude Code's own sign-in, in a clean environment. Safe to delete.
        for name in $(/usr/bin/env | /usr/bin/sed -n 's/^\\(\(prefix)[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset "$name"; done
        unset \(ClaudeCLIEnvironment.scrubbedKeys.joined(separator: " "))
        exec \(shellQuoted(binary)) auth login

        """
    }

    /// One `sh` argument, whatever it holds: the desktop app's copy lives under
    /// "Application Support", and a folder name may hold a quote.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Writes the file into `directory` (0755) and hands it to `terminal`.
    @MainActor
    static func launch(
        binary: String,
        directory: URL,
        terminal: URL?,
        open: @MainActor (URL, URL) async throws -> Void
    ) async -> Outcome {
        guard let terminal else { return .failed(ClaudeSignInCopy.terminalMissing) }
        let file = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try commandFile(binary: binary).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try await open(file, terminal)
            return .opened
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The button's launch: the file in Omelette's Application Support folder, Terminal found by
    /// its bundle id, opened through Launch Services.
    @MainActor
    static func launch(binary: String) async -> Outcome {
        await launch(
            binary: binary,
            directory: AgentPaths.appSupportURL,
            terminal: NSWorkspace.shared.urlForApplication(withBundleIdentifier: SessionActivator.terminalBundleID),
            open: { file, terminal in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration)
            }
        )
    }
}
