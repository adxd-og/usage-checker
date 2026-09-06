import SwiftUI
import AppKit

/// True while the app is running only as a host for the unit-test bundle.
///
/// Everything the app does at launch — polling, the status item, the notification
/// authorization prompt, the CLI-log scan behind the dashboard — is a side effect a
/// test run must not trigger; a permission dialog in particular would block the run.
enum AppEnvironment {
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}

@main
struct UsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Omelette", id: "dashboard") {
            if !AppEnvironment.isRunningTests {
                DashboardWindow(appState: AppState.shared)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Omelette") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Refresh now") {
                    AppState.shared.refreshNow()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var onboardingWindow: NSWindow?
    private var replayObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard !AppEnvironment.isRunningTests else { return }
        self.statusBar = StatusBarController()
        AppState.shared.bootstrap()
        // Hook → app channel: helper symlink + Unix socket. Started after bootstrap
        // so a hook that fires during launch never beats the poll's first snapshot.
        AgentChannel.shared.start()
        // `omelette` on the user's PATH points at this link; refreshing it here is what
        // survives moving the app to /Applications or updating it in place. Its own
        // statement rather than a line inside AgentChannel: the CLI has nothing to do
        // with the hook socket, and a failure here must not take the socket with it.
        do {
            try AgentPaths.refreshCLISymlink()
        } catch {
            NSLog("[UT] CLI symlink refresh failed: %@", String(describing: error))
        }
        // Presence for held permission requests: which app is in front, lock/sleep,
        // and the activation that releases a hold when the user returns to the terminal.
        PresenceMonitor.shared.start()
        // Delegate and category first: an authorization prompt can be answered, and
        // a notification acted on, before the next statement would have run.
        UsageNotifier.shared.startAgentNotifications()
        // Once per install, for someone already running Claude Code without hooks:
        // its Enable action needs the category above to exist first.
        UsageNotifier.shared.promptForHooksIfNeeded()
        UsageNotifier.shared.requestAuthorizationIfNeeded()
        scheduleOnboardingIfNeeded()
        replayObserver = NotificationCenter.default.addObserver(
            forName: .replayOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Unlinks the socket file so a helper spawned after we quit fails fast
        // (ECONNREFUSED on a stale path would still be within budget, but a
        // missing file is the cleaner signal).
        AgentChannel.shared.stop()
        flushCostCache()
    }

    /// The cost cache is written at most every five minutes, so up to five minutes of
    /// turns are usually still only in memory when the app quits — re-parsing them
    /// costs the next launch the very seconds the cache exists to save.
    ///
    /// The wait blocks the main thread, which is the only way the write lands: nothing
    /// after `applicationWillTerminate` returns is guaranteed to run. `JSONLAggregator`
    /// is a plain actor with no main-actor hop anywhere in its save path, so the task
    /// makes progress on the cooperative pool while we wait and cannot deadlock against
    /// us. Two seconds is the budget — encoding the largest cache measured here takes
    /// about 350 ms — and expiring it only means a colder next launch.
    ///
    /// `willTerminateNotification` fires at the same moment and would need the same
    /// blocking wait, so it buys nothing over doing it where the rest of the teardown
    /// already lives.
    private func flushCostCache() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await JSONLAggregator.shared.flushCache()
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            NSLog("[UT] cost cache flush did not finish within 2s; skipping it")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { focusExistingWindow() }
        return true
    }

    private func focusExistingWindow() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        for window in NSApp.windows where window.canBecomeMain && !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func scheduleOnboardingIfNeeded() {
        guard !SettingsStore.shared.hasSeenOnboarding else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor [weak self] in
                self?.openOnboarding()
            }
        }
    }

    @MainActor
    func openOnboarding() {
        NSApp.activate(ignoringOtherApps: true)

        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Omelette"
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.isReleasedWhenClosed = false
        window.center()

        let view = OnboardingView { [weak self, weak window] in
            window?.close()
            self?.onboardingWindow = nil
        }
        window.contentViewController = NSHostingController(rootView: view)
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
