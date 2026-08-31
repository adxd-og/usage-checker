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

    /// Whether the item's access list lets the binary at `path` decrypt it — i.e.
    /// whether that binary can read the secret with no permission panel.
    ///
    /// This is the preflight for the one read the app delegates to another binary.
    /// Reading an ACL is metadata access, not secret access: measured here, it returns
    /// the trust list from a binary the list doesn't name, with no dialog. Asking first
    /// is what keeps the delegated read prompt-proof — `security` inherits none of this
    /// process's no-UI state, so an untrusted `security` would raise from a background
    /// poll exactly the panel this file exists to prevent.
    static func aclTrusts(path: String, service: String) -> Bool {
        guard let acl = aclFns else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let item = ref,
              CFGetTypeID(item) == acl.itemTypeID()
        else { return false }
        let keychainItem = unsafeDowncast(item, to: SecKeychainItem.self)

        var access: SecAccess?
        guard acl.copyAccess(keychainItem, &access) == errSecSuccess, let access else { return false }
        var list: CFArray?
        guard acl.copyACLList(access, &list) == errSecSuccess,
              let acls = list as? [SecACL]
        else { return false }

        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        for entry in acls {
            // Only the ACL that governs decryption decides whether reading prompts;
            // the others cover writing, integrity and the partition list.
            guard let auths = acl.copyAuthorizations(entry) as? [String],
                  auths.contains("ACLAuthorizationDecrypt")
            else { continue }
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard acl.copyContents(entry, &apps, &description, &prompt) == errSecSuccess else { continue }
            guard let trusted = apps as? [SecTrustedApplication] else {
                // A nil app list means "any application" — nothing to check against.
                return true
            }
            for app in trusted {
                var data: CFData?
                guard acl.copyAppData(app, &data) == errSecSuccess,
                      let bytes = data as Data?,
                      let raw = String(data: bytes, encoding: .utf8)
                else { continue }
                // The path arrives NUL-terminated.
                let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                if URL(fileURLWithPath: trimmed).standardizedFileURL.path == wanted { return true }
            }
        }
        return false
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

    // The ACL entry points are deprecated too, and bound the same way for the same
    // reason. All-or-nothing: a partial set can't answer the question, so `aclTrusts`
    // reports "not trusted" and the delegated read is skipped.
    private typealias CopyAccessFn = @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias CopyACLListFn = @convention(c) (SecAccess, UnsafeMutablePointer<CFArray?>?) -> OSStatus
    private typealias CopyContentsFn = @convention(c) (
        SecACL,
        UnsafeMutablePointer<CFArray?>?,
        UnsafeMutablePointer<CFString?>?,
        UnsafeMutablePointer<SecKeychainPromptSelector>?
    ) -> OSStatus
    private typealias CopyAuthorizationsFn = @convention(c) (SecACL) -> CFArray
    private typealias CopyAppDataFn = @convention(c) (SecTrustedApplication, UnsafeMutablePointer<CFData?>) -> OSStatus
    private typealias ItemTypeIDFn = @convention(c) () -> CFTypeID

    private static let aclFns: (
        copyAccess: CopyAccessFn,
        copyACLList: CopyACLListFn,
        copyContents: CopyContentsFn,
        copyAuthorizations: CopyAuthorizationsFn,
        copyAppData: CopyAppDataFn,
        itemTypeID: ItemTypeIDFn
    )? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let copyAccess = dlsym(handle, "SecKeychainItemCopyAccess"),
              let copyACLList = dlsym(handle, "SecAccessCopyACLList"),
              let copyContents = dlsym(handle, "SecACLCopyContents"),
              let copyAuthorizations = dlsym(handle, "SecACLCopyAuthorizations"),
              let copyAppData = dlsym(handle, "SecTrustedApplicationCopyData"),
              let itemTypeID = dlsym(handle, "SecKeychainItemGetTypeID")
        else { return nil }
        return (
            unsafeBitCast(copyAccess, to: CopyAccessFn.self),
            unsafeBitCast(copyACLList, to: CopyACLListFn.self),
            unsafeBitCast(copyContents, to: CopyContentsFn.self),
            unsafeBitCast(copyAuthorizations, to: CopyAuthorizationsFn.self),
            unsafeBitCast(copyAppData, to: CopyAppDataFn.self),
            unsafeBitCast(itemTypeID, to: ItemTypeIDFn.self)
        )
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
