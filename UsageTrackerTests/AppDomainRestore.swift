import Foundation

/// Puts the app's real defaults domain back after a test that wrote settings to it. The
/// test host shares that domain with the running app, and the user can record the popover
/// shortcut there at any moment. KeyboardShortcuts keeps it in the same domain, so a plain
/// snapshot restore would put back the value from before the test and lose a shortcut
/// recorded meanwhile. The restore takes every other key from the snapshot and each live
/// key as it is when the restore runs.
enum AppDomainRestore {
    /// KeyboardShortcuts' key for `.peekUsage`: its private "KeyboardShortcuts_" prefix
    /// followed by the name's raw value.
    static let liveKeys = ["KeyboardShortcuts_peekUsage"]

    /// The snapshot with each live key as it is now: present with its current value, or
    /// absent when it is absent now.
    static func merged(saved: [String: Any]?, current: [String: Any]?, liveKeys: [String]) -> [String: Any] {
        var domain = saved ?? [:]
        for key in liveKeys {
            domain[key] = current?[key]
        }
        return domain
    }

    /// Writes `saved` back to `domainName`, except the live keys, which keep their current
    /// value.
    static func restore(_ saved: [String: Any]?, domainName: String) {
        let current = UserDefaults.standard.persistentDomain(forName: domainName)
        UserDefaults.standard.setPersistentDomain(
            merged(saved: saved, current: current, liveKeys: liveKeys),
            forName: domainName
        )
    }
}
