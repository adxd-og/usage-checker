import SwiftUI
import AppKit

@main
struct UsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Usage Checker", id: "dashboard") {
            DashboardWindow(appState: AppState.shared)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Usage Checker") {
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
        self.statusBar = StatusBarController()
        AppState.shared.bootstrap()
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
        window.title = "Welcome to Usage Checker"
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
