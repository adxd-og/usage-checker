import CodexBarCore
import Foundation

/// Which `claude` Omelette runs to sign in and to renew (spec 2026-10-25 § Design › Package 2,
/// The binary): the one on the login shell's PATH first, otherwise the newest copy the Claude
/// desktop app bundles. nil when there is neither. CodexBarCore's types are module-qualified:
/// its `UsageSnapshot` and friends collide with ours.
enum ClaudeBinaryLocator {
    /// Below `~/Library/Application Support`: `Claude/claude-code/<version>/<hash>/` and then this.
    static let bundledExecutable = "claude.app/Contents/MacOS/claude"

    /// The rule, with the machine passed in.
    static func locate(onPATH: () -> String?, applicationSupport: URL, fileManager: FileManager = .default) -> String? {
        if let path = onPATH() { return path }
        return newestBundled(applicationSupport: applicationSupport, fileManager: fileManager)
    }

    /// The desktop app's newest copy: highest version folder first, and within one version the
    /// copy modified last. `<version>` and `<hash>` change with every desktop update.
    static func newestBundled(applicationSupport: URL, fileManager: FileManager = .default) -> String? {
        let root = applicationSupport.appendingPathComponent("Claude/claude-code", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root.path) else { return nil }
        var best: (version: [Int], modified: Date, path: String)?
        for version in versions {
            let versionFolder = root.appendingPathComponent(version, isDirectory: true)
            guard let hashes = try? fileManager.contentsOfDirectory(atPath: versionFolder.path) else { continue }
            let key = versionKey(version)
            for hash in hashes {
                let binary = versionFolder
                    .appendingPathComponent(hash, isDirectory: true)
                    .appendingPathComponent(bundledExecutable)
                guard fileManager.isExecutableFile(atPath: binary.path) else { continue }
                let attributes = try? fileManager.attributesOfItem(atPath: binary.path)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                if let current = best {
                    let newer = isNewer(key, than: current.version)
                        || (key == current.version && modified > current.modified)
                    if newer { best = (key, modified, binary.path) }
                } else {
                    best = (key, modified, binary.path)
                }
            }
        }
        return best?.path
    }

    /// "2.1.308" → [2, 1, 308]; a part that is not a number counts as 0.
    static func versionKey(_ name: String) -> [Int] {
        name.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Part by part, a missing part being 0: "2.1" and "2.1.0" are the same version.
    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// The real lookup, off the main actor: the first call may wait for the login shell's PATH.
    static func locate() -> String? {
        locate(
            onPATH: { onLoginShellPATH() },
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
    }

    /// The login shell's PATH, captured once per launch by CodexBarCore (nvm, fnm, Homebrew:
    /// what a Finder-launched app's own PATH lacks).
    static func loginPATH() -> [String]? {
        capturedLoginPATH
    }

    /// CodexBarCore's cache stores a failed capture as nil and captures again on the next call
    /// (`PathEnvironment.swift:1278-1300`), so a login shell that times out would start on every
    /// signed-out poll. A static let runs its initializer once, on first use, thread-safely:
    /// one capture per launch, whatever came back.
    private static let capturedLoginPATH: [String]? = CodexBarCore.LoginShellPathCache.shared.currentOrCapture()

    /// `claude` the way CodexBarCore resolves it (its override variable, the login shell's
    /// PATH, Omelette's PATH, the well-known install folders), minus the interactive-shell
    /// fallbacks: a lookup runs on every signed-out poll and must not start the user's shell.
    private static func onLoginShellPATH() -> String? {
        CodexBarCore.BinaryLocator.resolveClaudeBinary(
            env: ProcessInfo.processInfo.environment,
            loginPATH: loginPATH(),
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil }
        )
    }
}
