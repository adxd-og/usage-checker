import Darwin
import Foundation

/// The machine's side of agent resources (spec 2026-11-19 agent resources § Which processes,
/// § Figures): the process table in one `sysctl`, and one process's CPU time and footprint from
/// `proc_pid_rusage`. Called only from `AgentResourceSampler`, an actor, so never on the main
/// actor. No test calls it: a test never reads the real process table (CLAUDE.md, Tests); the
/// rules it feeds are tested, and the gate compares its figures with Activity Monitor's.
enum AgentProcessTable {
    /// Every process as (pid, parent, tty, start time), in one `KERN_PROC_ALL` read: `sysctl`
    /// answers for other users' processes too, which the member walk needs to cross root's
    /// `login`. The start time is `kp_proc.p_starttime`, a C macro for
    /// `kp_proc.p_un.__p_starttime`, which is what Swift sees. Empty when the kernel refuses.
    /// The table can grow between asking its size and reading it, so the buffer has room to
    /// spare and a short one (`ENOMEM`) is asked again, three times at most.
    static func read() -> [AgentResourceRules.ProcessRow] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            var bytes = processes.count * stride
            let status = processes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &bytes, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            var names: [dev_t: String] = [:]
            return processes.prefix(bytes / stride).compactMap { info in
                let pid = info.kp_proc.p_pid
                guard pid > 0 else { return nil }
                let started = info.kp_proc.p_un.__p_starttime
                return AgentResourceRules.ProcessRow(
                    pid: pid,
                    parent: info.kp_eproc.e_ppid,
                    tty: ttyPath(info.kp_eproc.e_tdev, names: &names),
                    startedAt: Date(
                        timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
                    )
                )
            }
        }
        return []
    }

    /// One process's CPU seconds and physical footprint, or nil for a process
    /// `proc_pid_rusage` refuses (another user's: errno 1, measured 2026-11-19) or one that has
    /// gone. The times are mach ticks, turned into seconds with `mach_timebase_info`.
    static func usage(_ pid: pid_t) -> AgentResourceRules.Usage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
        }
        guard status == 0 else { return nil }
        // A process's own time and its reaped children's: a reaped child's time, and its
        // children's, shows in the parent's (measured on macOS 27.2).
        let ticks = info.ri_user_time &+ info.ri_system_time &+ info.ri_child_user_time &+ info.ri_child_system_time
        return AgentResourceRules.Usage(
            cpuSeconds: Double(ticks) * secondsPerTick,
            footprintBytes: Int(clamping: info.ri_phys_footprint)
        )
    }

    /// `/dev/ttys003` for a controlling terminal; nil for none (`NODEV`, -1) or a device
    /// that has no name. Each device is named once per table.
    ///
    /// `devname_r` into a buffer of this call's own, not `devname`: that one answers from one
    /// buffer the whole process shares, and `HostProcessWalk` calls it from a detached task on a
    /// tmux jump while the sampler reads here. A name read while the other thread rewrote it
    /// would put a process under another tab's tty for a sample.
    private static func ttyPath(_ device: dev_t, names: inout [dev_t: String]) -> String? {
        guard device != -1, device != 0 else { return nil }
        if let known = names[device] { return known }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard let name = devname_r(device, mode_t(S_IFCHR), &buffer, Int32(buffer.count)) else { return nil }
        let path = "/dev/" + String(cString: name)
        names[device] = path
        return path
    }

    /// Seconds per mach tick (125 / 3 ns on Apple silicon).
    private static let secondsPerTick: Double = {
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom > 0 else { return 1e-9 }
        return Double(base.numer) / Double(base.denom) / 1_000_000_000
    }()
}
