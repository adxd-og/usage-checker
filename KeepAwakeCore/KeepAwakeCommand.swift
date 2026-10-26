import Foundation

/// Runs a system tool and hands back its exit status and output. Used by the daemon (pmset as
/// root) and by the app's reset (pmset as the user, osascript for the administrator prompt).
enum KeepAwakeCommand {
    static let pmset = "/usr/bin/pmset"
    static let osascript = "/usr/bin/osascript"

    /// Synchronous: call it off the main thread. A tool that cannot start comes back with
    /// status -1 and the launch error; one that outlives `timeout` is terminated.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> KeepAwakeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return KeepAwakeCommandResult(status: -1, output: error.localizedDescription)
        }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: waiting on a process whose pipe is full deadlocks.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return KeepAwakeCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
