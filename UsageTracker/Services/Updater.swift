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

    /// The two Sparkle facts Settings shows, kept here as `@Published` copies. When they
    /// were read straight through, nothing told a view they had changed: after "Check
    /// for updates now" the "Last check" line kept the old time until a poll happened
    /// to redraw the window. Both are KVO-compliant on `SPUUpdater`.
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    private var stateObservations: [NSKeyValueObservation] = []

    override init() {
        // startingUpdater: Sparkle starts its scheduled checks at once — for a build
        // that may update itself at all (`updatesItself`); a Debug one never starts.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: Self.updatesItself(
                isDebugBuild: Self.isDebugBuild, bundlePath: Bundle.main.bundlePath
            ),
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        stateObservations = Self.mirrorState(
            of: controller.updater,
            canCheck: \.canCheckForUpdates,
            lastCheck: \.lastUpdateCheckDate,
            onCanCheck: { [weak self] in self?.canCheckForUpdates = $0 },
            onLastCheck: { [weak self] in self?.lastUpdateCheckDate = $0 }
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether this build may check for and install updates on its own. A Debug build,
    /// or any bundle running out of a DerivedData tree, never does: on 2026-09-24 a
    /// Debug instance launched from `build/DerivedData` took the public 2.7.0 update,
    /// Sparkle replaced its bundle with the release app and relaunched it, and the
    /// Release `omelette-hook` left in the test bundle failed 50 hook tests in the next
    /// gate run. Sparkle's own setting is left alone: it lives in the shared defaults
    /// domain, and switching it off here would switch it off for the release app too.
    nonisolated static func updatesItself(isDebugBuild: Bool, bundlePath: String) -> Bool {
        !isDebugBuild && !bundlePath.contains("/DerivedData/")
    }

    private nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Feeds two KVO-compliant properties of `source` into the callbacks: the current
    /// values at once, then every change. Generic over the source, so a test can hand
    /// it an `NSObject` with the same two properties instead of starting Sparkle. A
    /// change that arrives off the main thread is hopped onto it.
    nonisolated static func mirrorState<Source: NSObject>(
        of source: Source,
        canCheck: KeyPath<Source, Bool>,
        lastCheck: KeyPath<Source, Date?>,
        onCanCheck: @escaping @MainActor @Sendable (Bool) -> Void,
        onLastCheck: @escaping @MainActor @Sendable (Date?) -> Void
    ) -> [NSKeyValueObservation] {
        [
            source.observe(canCheck, options: [.initial, .new]) { _, change in
                guard let value = change.newValue else { return }
                onMain { onCanCheck(value) }
            },
            source.observe(lastCheck, options: [.initial, .new]) { _, change in
                // `Date??`: the outer optional is "the change carried no value", the
                // inner one "no check has finished yet". Both mean nil on screen.
                let value = change.newValue ?? nil
                onMain { onLastCheck(value) }
            },
        ]
    }

    private nonisolated static func onMain(_ update: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { update() }
        } else {
            DispatchQueue.main.async { update() }
        }
    }

    /// "Last check: 24 Sep 2026, 14:15" in the user's own date order and clock; nil
    /// before Sparkle has finished a first check.
    nonisolated static func lastCheckText(
        _ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        guard let date else { return nil }
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        let day = date.formatted(style.day().month(.abbreviated).year())
        let time = date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone
        ))
        return "Last check: \(day), \(time)"
    }

    /// Sparkle's own scheduled check runs on its own cadence and can miss a machine
    /// that sleeps between them. Opening a window is a cheap second trigger — but
    /// the popover is opened dozens of times a day, so once an hour is the cap.
    nonisolated static let openCheckInterval: TimeInterval = 3600

    nonisolated static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= openCheckInterval
    }

    /// Both clocks have to say yes. Sparkle's `lastUpdateCheckDate` is only set when
    /// a check *completes*, so a machine that has never reached the feed — offline,
    /// or a fresh install — keeps it nil and would otherwise start a check on every
    /// single popover open.
    nonisolated static func shouldCheck(sparkleLast: Date?, ownLast: Date?, now: Date) -> Bool {
        isDue(lastCheck: sparkleLast, now: now) && isDue(lastCheck: ownLast, now: now)
    }

    /// When this class last *started* a background check, whether or not it finished.
    private var lastOpenCheck: Date?

    /// Silent: Sparkle only puts UI on screen when there is something to install.
    /// Honors the user's "check automatically" setting — an update check they
    /// turned off must not come back through a side door.
    func checkInBackgroundIfDue(now: Date = Date()) {
        // Sparkle's own values, not the copies above: a KVO notification that never
        // arrived must not be able to switch background checks off.
        let updater = controller.updater
        guard automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
        guard Self.shouldCheck(sparkleLast: updater.lastUpdateCheckDate, ownLast: lastOpenCheck, now: now) else { return }
        lastOpenCheck = now
        updater.checkForUpdatesInBackground()
    }
}
