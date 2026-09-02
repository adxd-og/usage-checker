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
        // Delegate and category first: an authorization prompt can be answered, and
        // a notification acted on, before the next statement would have run.
        UsageNotifier.shared.startAgentNotifications()
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
