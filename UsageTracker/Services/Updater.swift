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
}
