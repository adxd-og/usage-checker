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

    /// Exit 2 for every way the file can be missing — not written yet, too old,
    /// unreadable, from another version. A script asking "is Omelette up?" gets one
    /// answer, and the sentence goes to stderr so `omelette status | …` pipes nothing
    /// but numbers.
    static func status(json: Bool) -> Int32 {
        let url = StatusFile.url()
        let now = Date()
        guard let snapshot = StatusFile.load(from: url), snapshot.isFresh(now: now) else {
            err(CLIText.notRunning + "\n")
            return CLIText.noDataExitCode
        }
        if json {
            // The file verbatim: re-encoding it would mean two spellings of the same
            // bytes, and `omelette status --json | jq` should see what is on disk.
            guard var data = StatusFile.read(from: url) else {
                err(CLIText.notRunning + "\n")
                return CLIText.noDataExitCode
            }
            if data.last != 0x0A { data.append(0x0A) }
            FileHandle.standardOutput.write(data)
            return 0
        }
        out(StatusText.render(snapshot: snapshot, now: now))
        return 0
    }

    /// Always exit 0, always exactly one line. Claude Code shows whatever we print for
    /// the rest of the session, so "not running" is an empty line rather than a word.
    static func statusLine(provider: String) -> Int32 {
        drainStandardInput()
        let snapshot = StatusFile.load(from: StatusFile.url())
        out(StatusLineText.render(snapshot: snapshot, provider: provider, now: Date()) + "\n")
        return 0
    }

    /// The MCP server: newline-delimited JSON-RPC on stdin and stdout until the client
    /// closes the pipe, which is how the spec says a stdio server shuts down.
    ///
    /// `status.json` is re-read for every request and never held between them. A
    /// server that cached would tell an agent what the limits were when the session
    /// started, which is the one moment the answer does not matter.
    ///
    /// Nothing but JSON-RPC ever reaches stdout — a stray `print` in this loop is a
    /// protocol violation, and the client would report the server as broken. Anything
    /// worth saying goes to stderr, and at present nothing does.
    static func mcp() -> Int32 {
        let url = StatusFile.url()
        while let line = readLine(strippingNewline: true) {
            guard let response = MCPServer.handle(line, snapshot: StatusFile.load(from: url), now: Date()) else {
                continue
            }
            out(response + "\n")
        }
        return 0
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
