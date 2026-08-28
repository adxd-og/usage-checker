import Foundation
import LocalAuthentication
import Security

/// Keeps keychain access silent: no Allow/Deny panel, no password panel, ever, from a
/// background refresh.
///
/// What actually works here was measured on this codebase's target OS, because the
/// obvious answer is wrong. Reading `Claude Code-credentials` from a binary its ACL
/// doesn't trust:
///
///   * `LAContext.interactionNotAllowed` + `kSecUseAuthenticationUIFail` → **prompts
///     anyway**. Those flags govern the LocalAuthentication path; a legacy trust-list
///     ACL doesn't consult them. (This is what CodexBar's `KeychainNoUIQuery` does, and
///     why copying it wasn't enough.)
///   * `SecKeychainSetUserInteractionAllowed(false)` → returns `errSecAuthFailed`
///     immediately, no panel. This is the one that holds.
///
/// A *locked* login keychain is a third case that neither flag covers: it answers with a
/// password panel regardless. The only defence is not to ask, so `isDefaultKeychainUnlocked`
/// gates the reads.
///
/// The interaction flag is process-global, so every keychain call in the app funnels
/// through `withoutUI`/`withUI` under one lock — otherwise a background poll could strip
/// the dialog from the Settings button firing at the same moment.
enum KeychainNoUI {
    private static let uiFailPolicy = resolveUIFailPolicy()

    private static let lock = NSLock()

    /// Runs a keychain call with this process's keychain UI switched off. Any prompt the
    /// call would have raised becomes an error status instead.
    static func withoutUI<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        setUserInteractionAllowed(false)
        defer { setUserInteractionAllowed(true) }
        return body()
    }

    /// Runs a keychain call that is *allowed* to prompt — a user-initiated read. Takes
    /// the same lock so it can't run while UI is switched off.
    static func withUI<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        setUserInteractionAllowed(true)
        return body()
    }

    private static func setUserInteractionAllowed(_ allowed: Bool) {
        guard let setter = legacy.setUserInteraction else { return }
        _ = setter(DarwinBoolean(allowed))
    }

    /// Applies the no-UI policy to a `SecItemCopyMatching` query. Cheap, and it still
    /// covers the LocalAuthentication path — but it is not what stops the ACL panel.
    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    /// True when the status means "would have needed a prompt", not "went wrong".
    static func isInteractionRequired(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    /// Whether the default (login) keychain is currently unlocked.
    ///
    /// This is the gate that actually keeps background polling silent. A locked login
    /// keychain answers *any* read of a stored secret with a password panel, and —
    /// measured on macOS 26.6, not assumed — neither `kSecUseAuthenticationUIFail` nor
    /// `SecKeychainSetUserInteractionAllowed(false)` suppresses that panel: both calls
    /// sat there waiting for the user, then returned `errSecAuthFailed`. The only way
    /// not to raise it is not to ask, so callers check this first and skip the read.
    ///
    /// The status call itself is free and silent: it reads the keychain's lock state,
    /// not its contents (bits 7 = unlocked/readable/writable, 2 = locked here).
    static var isDefaultKeychainUnlocked: Bool {
        guard let copyDefault = legacy.copyDefault, let getStatus = legacy.getStatus else {
            // Without the legacy entry points we can't tell — assume unlocked and let
            // the query's own no-UI policy do what it can.
            return true
        }
        var keychain: SecKeychain?
        guard copyDefault(&keychain) == errSecSuccess else { return true }
        var bits: UInt32 = 0
        guard getStatus(keychain, &bits) == errSecSuccess else { return true }
        return (bits & kSecUnlockStateStatus) != 0
    }

    // `SecKeychainCopyDefault` / `SecKeychainGetStatus` are deprecated, and there is no
    // modern replacement that reports lock state. Bind them at runtime so the
    // deprecation never becomes a build error.
    private typealias CopyDefaultFn = @convention(c) (UnsafeMutablePointer<SecKeychain?>) -> OSStatus
    private typealias GetStatusFn = @convention(c) (SecKeychain?, UnsafeMutablePointer<UInt32>) -> OSStatus
    private typealias SetInteractionFn = @convention(c) (DarwinBoolean) -> OSStatus

    private static let legacy: (
        copyDefault: CopyDefaultFn?,
        getStatus: GetStatusFn?,
        setUserInteraction: SetInteractionFn?
    ) = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return (nil, nil, nil)
        }
        // Deliberately not dlclose'd: the function pointers must outlive this call, and
        // the framework is already resident in every process that links Security.
        let copyDefault = dlsym(handle, "SecKeychainCopyDefault").map {
            unsafeBitCast($0, to: CopyDefaultFn.self)
        }
        let getStatus = dlsym(handle, "SecKeychainGetStatus").map {
            unsafeBitCast($0, to: GetStatusFn.self)
        }
        let setInteraction = dlsym(handle, "SecKeychainSetUserInteractionAllowed").map {
            unsafeBitCast($0, to: SetInteractionFn.self)
        }
        return (copyDefault, getStatus, setInteraction)
    }()

    /// `kSecUseAuthenticationUIFail` is deprecated, so referencing it at compile time
    /// is a warning (and a future build error). Resolve the real constant at runtime
    /// and keep the documented literal as the fallback.
    private static func resolveUIFailPolicy() -> String {
        let fallback = "u_AuthUIF"
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return fallback
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return fallback }
        return (symbol.assumingMemoryBound(to: CFString?.self).pointee as String?) ?? fallback
    }
}
