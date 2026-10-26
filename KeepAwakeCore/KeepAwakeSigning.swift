import Foundation
import Security

/// The names launchd, XPC and the bundle share for the keep-awake helper.
enum KeepAwakeIdentity {
    static let label = "com.usagetracker.app.keepawake"
    static let machServiceName = label
    static let plistName = "com.usagetracker.app.keepawake.plist"
    static let helperName = "omelette-keepawake"
    static let appIdentifier = "com.usagetracker.app"
    /// Written by the daemon only, as root (plan D8).
    static let stateFileURL = URL(fileURLWithPath: "/Library/Application Support/Omelette/keepawake.json")
}

/// Code-signing requirements for the two ends of the XPC connection (spec 2026-10-26,
/// § Helper › XPC; plan D2, D3). The team comes from the running code's own signature, so the
/// team ID never enters the repository, and Debug (Apple Development) and Release (Developer
/// ID) builds both pass. Without a valid team there is no requirement, and so no connection.
enum KeepAwakeSigning {
    /// A team identifier is ten characters, each an uppercase letter or a digit.
    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
    }

    /// What the daemon demands of its caller: the app's identifier, signed by the daemon's team.
    static func callerRequirement(teamID: String?) -> String? {
        guard let team = teamID, isTeamIdentifier(team) else { return nil }
        return "anchor apple generic and identifier \"\(KeepAwakeIdentity.appIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// What the app demands of the daemon: the app's team only. No identifier clause (D3): a
    /// bare tool signs with its product name as identifier (measured on omelette-hook), not
    /// its bundle id, and `.privileged` already restricts the lookup to launchd's system domain.
    static func helperRequirement(teamID: String?) -> String? {
        guard let team = teamID, isTeamIdentifier(team) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team the running code is signed by; nil for unsigned or ad-hoc code. Not
    /// unit-tested: it reads the test host's own signature.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
