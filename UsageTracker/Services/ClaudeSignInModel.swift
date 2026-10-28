import Combine
import Foundation

/// The Sign in button's state (spec 2026-10-25 § Design › Package 2, Sign in): whether a
/// `claude` is on this Mac, and what the last click did. The words are `ClaudeSignInCopy`'s.
@MainActor
final class ClaudeSignInModel: ObservableObject {
    static let shared = ClaudeSignInModel()

    @Published private(set) var binary: String?
    @Published private(set) var hasLookedForBinary = false
    @Published private(set) var note: ClaudeSignInNote?

    private init() {}

    var binaryFound: Bool { Self.binaryFound(binary: binary, hasLooked: hasLookedForBinary) }

    /// Before the first look the button shows, and a click looks again before it opens Terminal.
    nonisolated static func binaryFound(binary: String?, hasLooked: Bool) -> Bool {
        binary != nil || !hasLooked
    }

    /// Off the main actor: the first look may wait for the login shell's PATH.
    func lookForBinary() async {
        let found = await Task.detached(priority: .utility) { ClaudeBinaryLocator.locate() }.value
        binary = found
        hasLookedForBinary = true
    }

    /// The button: Terminal runs Claude Code's own sign-in. Never silent — a failure is said in
    /// the help line — and no renewal starts while the user signs in.
    /// A click while the last one is still opening Terminal does nothing: one sign-in at a time.
    private var isLaunching = false

    func signIn() async {
        guard !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }
        await lookForBinary()
        guard let binary else {
            note = .failed(ClaudeSignInCopy.binaryMissing)
            return
        }
        // Held before Terminal opens, so no renewal starts beside the sign-in.
        await ClaudeRenewalGate.shared.signInLaunched(at: Date())
        switch await ClaudeSignInLauncher.launch(binary: binary) {
        case .opened:
            note = .pending
        case .failed(let detail):
            await ClaudeRenewalGate.shared.signInDidNotOpen()
            note = .failed(detail)
        }
    }
}
