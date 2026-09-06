import Foundation

// omelette — Omelette's numbers in the terminal.
//
// Contract: read ~/Library/Application Support/UsageTracker/status.json and print it.
// Never start the app, never open a socket, never touch the network, never write
// anywhere. Foundation only — no AppKit, no Security. Every command is a file read and
// a string, so the work is under 50 ms; the only thing that can block is `mcp`, which
// is a server and blocks on its own stdin by design.

enum CLIMain {
    static func run() -> Never {
        switch CLICommand.parse(Array(CommandLine.arguments.dropFirst())) {
        case .help:
            out(CLIText.usage + "\n")
            exit(0)
        case .version:
            out("omelette \(CLIText.version)\n")
            exit(0)
        case .status(let json):
            exit(status(json: json))
        case .statusLine(let provider):
            exit(statusLine(provider: provider))
        case .mcp:
            exit(mcp())
        case .usageError(let message):
            err(message + "\n\n" + CLIText.usage + "\n")
            exit(CLIText.usageExitCode)
        }
    }

    // MARK: - Commands (filled in by the tasks that own them)

    static func status(json: Bool) -> Int32 {
        err(CLIText.notRunning + "\n")
        return CLIText.noDataExitCode
    }

    static func statusLine(provider: String) -> Int32 {
        drainStandardInput()
        out("\n")
        return 0
    }

    static func mcp() -> Int32 {
        0
    }

    // MARK: - I/O

    /// `FileHandle`, not `print`: stdout through Foundation is unbuffered, which is
    /// what a JSON-RPC peer waiting on one line needs, and what keeps a status line
    /// from arriving after Claude Code has given up on us.
    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func err(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Claude Code writes its session JSON to our stdin and closes it. We read nothing
    /// out of it — the numbers this line shows are Omelette's, not the session's, and
    /// Claude Code already prints its own model name — but leaving the pipe unread
    /// risks a write error on their side, so it is drained and dropped.
    ///
    /// Only when stdin is a pipe: run by hand in a terminal there is nothing to read
    /// and `readToEnd` would sit there until the user pressed ^D.
    static func drainStandardInput() {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return }
        _ = try? FileHandle.standardInput.readToEnd()
    }
}

CLIMain.run()
