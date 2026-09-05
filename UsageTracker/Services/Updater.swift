import Foundation
import AppKit
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest of the
/// app doesn't have to know about Sparkle types.
///
/// Configuration lives in Info.plist:
///   - `SUFeedURL` — appcast.xml URL (e.g. `https://adxd-og.github.io/usage-checker/appcast.xml`)
///   - `SUPublicEDKey` — EdDSA public key (base64). Generate with `bin/generate_keys` from Sparkle.
///
/// See CONTRIBUTING.md for release / signing instructions.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    override init() {
        // startingUpdater: true → Sparkle starts automatic background checks immediately.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    /// Sparkle's own scheduled check runs on its own cadence and can miss a machine
    /// that sleeps between them. Opening a window is a cheap second trigger — but
    /// the popover is opened dozens of times a day, so once an hour is the cap.
    nonisolated static let openCheckInterval: TimeInterval = 3600

    nonisolated static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= openCheckInterval
    }

    /// Silent: Sparkle only puts UI on screen when there is something to install.
    /// Honors the user's "check automatically" setting — an update check they
    /// turned off must not come back through a side door.
    func checkInBackgroundIfDue(now: Date = Date()) {
        guard automaticallyChecksForUpdates, canCheckForUpdates else { return }
        guard Self.isDue(lastCheck: lastUpdateCheckDate, now: now) else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}
