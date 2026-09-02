import Foundation

/// The terminal / IDE this hook ultimately runs under, found by walking the parent
/// chain: `omelette-hook ← sh ← claude ← zsh ← login ← iTermServer ← iTerm2`.
struct HostProcess {
    var pid: Int32?
    var bundleID: String?
    var tty: String?

    /// Terminals and IDEs the app knows how to bring to the front (package 4).
    static let knownBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
    ]
    static let maxHops = 32

    /// Walks from `pid` up to launchd. `tty` is the first controlling terminal seen
    /// (ours when the agent passed it on, otherwise the agent's own). The host is the
    /// innermost known terminal/IDE, reported with the pid of the outermost process of
    /// the same app (VS Code's Electron main process, not its plugin helper). Without a
    /// known host the outermost `.app` ancestor is reported, so a click can still
    /// activate something.
    static func describe(from pid: pid_t = getpid()) -> HostProcess {
        var result = HostProcess()
        var known: (pid: pid_t, bundleID: String)?
        var outermostApp: (pid: pid_t, bundleID: String)?
        var current = pid
        var hops = 0
        while current > 1, hops < maxHops, let record = ProcessRecord.read(current) {
            hops += 1
            if result.tty == nil { result.tty = record.tty }
            if let bundleID = record.bundleID {
                if let found = known, found.bundleID == bundleID {
                    known = (current, bundleID)
                } else if known == nil, knownBundleIDs.contains(bundleID) {
                    known = (current, bundleID)
                }
                outermostApp = (current, bundleID)
            }
            current = record.parentPID
        }
        if let host = known ?? outermostApp {
            result.pid = host.pid
            result.bundleID = host.bundleID
        }
        return result
    }
}

/// One process, read through `sysctl`. `proc_pidinfo(PROC_PIDTBSDINFO)` refuses
/// other users' processes and the chain crosses root's `login`; `sysctl` answers
/// for every pid.
struct ProcessRecord {
    let parentPID: pid_t
    let tty: String?
    let bundleID: String?

    static func read(_ pid: pid_t) -> ProcessRecord? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return ProcessRecord(
            parentPID: info.kp_eproc.e_ppid,
            tty: ttyPath(info.kp_eproc.e_tdev),
            bundleID: bundleID(ofExecutable: executablePath(pid))
        )
    }

    /// `e_tdev` is NODEV (-1) for a process without a controlling terminal.
    private static func ttyPath(_ device: dev_t) -> String? {
        guard device != -1, device != 0, let name = devname(device, mode_t(S_IFCHR)) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // proc_pidpath returns the byte count, so no NUL hunting is needed.
        return String(decoding: buffer[..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…`
    /// → the outer app (first `.app/`), read from its Info.plist — no AppKit needed.
    private static func bundleID(ofExecutable path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<range.lowerBound]) + ".app"
        return Bundle(path: appPath)?.bundleIdentifier
    }
}
