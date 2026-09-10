import Foundation

/// Which build is this, and where does it live?
///
/// Both answers used to exist only in Settings, three clicks from anything the app
/// actually shows — so a bug report started with "what version are you on?" and the
/// project page was something you had to already know about. The popover footer and
/// the dashboard sidebar carry this label instead, linked to the repository.
enum AppVersion {
    /// The public repository. Anonymous handle: this is the name the app ships under.
    static let githubURL = URL(string: "https://github.com/adxd-og/usage-checker")!

    /// "Omelette 2.4.1". The build number is deliberately absent: Settings' own row
    /// keeps "2.4.1 (39)" for bug reports, while a footer label is for recognition
    /// and has to stay short. `build` is taken all the same, so the caller can hand
    /// over the bundle's pair and let this rule decide what reaches the screen.
    /// A bundle with no version at all is just the app's name.
    nonisolated static func label(version: String?, build: String?) -> String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return "Omelette" }
        return "Omelette \(version)"
    }

    /// The running bundle's label. In the app that is Omelette.app; under XCTest the
    /// test host is the same bundle, which is what makes it readable in a test.
    static var current: String {
        let info = Bundle.main.infoDictionary
        return label(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }
}
