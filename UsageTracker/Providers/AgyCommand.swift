import Foundation

/// Antigravity's own CLI, asked for the account's quota while the app is closed. Found and
/// started without a shell: a menu-bar app started by launchd does not inherit the login
/// shell's PATH.
enum AgyCommand {
    /// Where agy is, as the fleet finds it plus the installer's default: `AGY_BIN` (an
    /// absolute path, or one under `~/`), then `~/.local/bin/agy`, then each absolute PATH
    /// entry in order. The first candidate `isExecutable` accepts wins; nil when none does.
    /// A bare `AGY_BIN` name ("agy") is no path and is ignored; PATH covers it.
    static func executablePath(
        environment: [String: String],
        homeDirectory: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        var candidates: [String] = []
        if let bin = environment["AGY_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if bin.hasPrefix("/") {
                candidates.append(bin)
            } else if bin.hasPrefix("~/") {
                candidates.append(homeDirectory + String(bin.dropFirst()))
            }
        }
        candidates.append(homeDirectory + "/.local/bin/agy")
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where entry.hasPrefix("/") {
            candidates.append(entry.hasSuffix("/") ? entry + "agy" : entry + "/agy")
        }
        return candidates.first(where: isExecutable)
    }
}
