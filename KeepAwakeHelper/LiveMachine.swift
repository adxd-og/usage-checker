import Foundation
import IOKit
import IOKit.ps

/// The machine the service drives, for real: pmset as root, IOKit for the battery and the lid,
/// and two wall-clock timers (the tick and the idle exit). Covered by the owner's check, not by
/// unit tests; the service it feeds is tested against a fake.
enum LiveMachine {
    static func make(scheduler: WallClockScheduler, exitScheduler: WallClockScheduler) -> KeepAwakeMachine {
        KeepAwakeMachine(
            setSleepDisabled: { value in
                KeepAwakeCommand.run(KeepAwakeCommand.pmset, ["-a", "disablesleep", value ? "1" : "0"], timeout: 10)
            },
            readSleepDisabled: {
                let result = KeepAwakeCommand.run(KeepAwakeCommand.pmset, ["-g"], timeout: 10)
                return result.status == 0 ? KeepAwakeReadings.flag(fromPmset: result.output) : .unreadable
            },
            sleepNow: { KeepAwakeCommand.run(KeepAwakeCommand.pmset, ["sleepnow"], timeout: 10) },
            lid: { LiveMachine.lid() },
            power: { LiveMachine.power() },
            schedule: { scheduler.schedule($0) },
            scheduleExit: { exitScheduler.schedule($0) },
            // Never returns: the idle exit and the stop path decide and exit in one step on
            // the service's actor.
            terminate: { status in exit(status) },
            // Only the stop path waits, at most 4 s, on its way out.
            pause: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    /// Both clamshell keys from the one IOPMrootDomain entry (plan D5). No entry reads as an
    /// open lid that would not sleep.
    static func lid() -> KeepAwakeLid {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return KeepAwakeLid(closed: false, causesSleep: false) }
        defer { IOObjectRelease(root) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return KeepAwakeLid(closed: false, causesSleep: false)
        }
        let dictionary = properties?.takeRetainedValue() as? [String: Any] ?? [:]
        return KeepAwakeReadings.lid(fromRootDomain: dictionary)
    }

    /// The internal battery from IOKit's power sources; nil on a Mac without one.
    static func power() -> KeepAwakePower? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let descriptions = sources.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }
        return KeepAwakeReadings.power(fromDescriptions: descriptions)
    }
}

/// A one-shot wall-clock timer: the deadline holds across clock changes and sleep. `onFire`
/// is set once, before the first `schedule`.
final class WallClockScheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    var onFire: (@Sendable () -> Void)?

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    /// Replaces the pending timer; nil cancels it.
    func schedule(_ date: Date?) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            guard let date else { return }
            let t = date.timeIntervalSince1970
            let seconds = t.rounded(.down)
            let deadline = DispatchWallTime(timespec: timespec(tv_sec: Int(seconds), tv_nsec: Int((t - seconds) * 1_000_000_000)))
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(wallDeadline: deadline)
            let onFire = self.onFire
            timer.setEventHandler { onFire?() }
            timer.resume()
            self.timer = timer
        }
    }
}

/// IOKit's power-source notifications, on the main run loop. The C callback captures nothing;
/// the observer is retained for the life of the process through the context pointer.
final class PowerObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func install() {
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            NSLog("[keepawake] no power-source notifications; the tick reads the battery")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
