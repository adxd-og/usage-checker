import AppKit
import XCTest
@testable import Omelette

@MainActor
final class PresenceMonitorTests: XCTestCase {
    private let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")

    func testMatchesUsesThePIDWhenTheHostHasOne() {
        XCTAssertTrue(PresenceMonitor.matches(frontmost: (4242, "com.googlecode.iterm2"), host: iterm))
        XCTAssertTrue(PresenceMonitor.matches(frontmost: (4242, nil), host: iterm), "pid alone is enough")
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (1, "com.googlecode.iterm2"), host: iterm),
                       "same app, other process: a second iTerm instance is not this session's window")
        XCTAssertFalse(PresenceMonitor.matches(frontmost: nil, host: iterm))
    }

    func testMatchesFallsBackToTheBundleIDWhenThereIsNoPID() {
        let byBundle = AgentHostInfo(pid: nil, bundleID: "com.apple.Terminal", tty: nil)
        XCTAssertTrue(PresenceMonitor.matches(frontmost: (77, "com.apple.Terminal"), host: byBundle))
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, "com.googlecode.iterm2"), host: byBundle))
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, nil), host: byBundle))
    }

    func testAHostWithoutIdentityNeverMatches() {
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, "com.apple.Terminal"), host: .none))
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, "x"), host: AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys001")))
    }

    func testIsUserAtHostIsFalseWhenLockedOrAsleep() {
        let monitor = PresenceMonitor(frontmost: { (4242, "com.googlecode.iterm2") })
        XCTAssertTrue(monitor.isUserAt(host: iterm))
        monitor.setLocked(true)
        XCTAssertFalse(monitor.isUserAt(host: iterm), "a locked screen means nobody is at the terminal")
        monitor.setLocked(false)
        monitor.setAsleep(true)
        XCTAssertFalse(monitor.isUserAt(host: iterm))
        monitor.setAsleep(false)
        XCTAssertTrue(monitor.isUserAt(host: iterm))
    }

    func testInjectedLockStateWinsOverTheTrackedOne() {
        let monitor = PresenceMonitor(frontmost: { (4242, "com.googlecode.iterm2") }, isLockedOrAsleep: { true })
        XCTAssertTrue(monitor.isLockedOrAsleep)
        XCTAssertFalse(monitor.isUserAt(host: iterm))
    }

    func testFrontmostIsReadAtCallTimeNotAtInit() {
        final class Front: @unchecked Sendable { var value: PresenceMonitor.Frontmost? = (1, "com.other") }
        let front = Front()
        let monitor = PresenceMonitor(frontmost: { front.value })
        XCTAssertFalse(monitor.isUserAt(host: iterm))
        front.value = (4242, "com.googlecode.iterm2")
        XCTAssertTrue(monitor.isUserAt(host: iterm))
    }

    func testActivationNotificationsReachOnActivationAfterStart() {
        let monitor = PresenceMonitor(frontmost: { nil })
        var seen: [Int32] = []
        monitor.onActivation = { seen.append($0.processIdentifier) }
        monitor.start()
        monitor.start()   // idempotent: no double delivery
        defer { monitor.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )

        let deadline = Date().addingTimeInterval(1)
        while seen.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(seen, [getpid()])
    }

    func testStopUnregisters() {
        let monitor = PresenceMonitor(frontmost: { nil })
        var count = 0
        monitor.onActivation = { _ in count += 1 }
        monitor.start()
        monitor.stop()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(count, 0)
    }
}
