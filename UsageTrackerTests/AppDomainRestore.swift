import Foundation

/// Puts the app's real defaults domain back after a test that wrote settings to it. The
/// test host shares that domain with the running app, so a test that changes a setting
/// takes a snapshot first and hands it back here.
enum AppDomainRestore {
    /// Writes `saved` back to `domainName`; with nothing saved, the domain is left empty.
    static func restore(_ saved: [String: Any]?, domainName: String) {
        UserDefaults.standard.setPersistentDomain(saved ?? [:], forName: domainName)
    }
}
