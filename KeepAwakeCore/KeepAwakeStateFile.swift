import Foundation

/// The daemon's state on disk (plan D8): `{"version":1,"state":…}`, written by the daemon only
/// (root-owned in `/Library/Application Support/Omelette/`), so `state()` answers after a
/// restart. A missing file, garbage or another version reads as nothing.
struct KeepAwakeStateFile: Sendable {
    let url: URL

    static let currentVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var state: KeepAwakeState
        /// What a stop could not clear (Task 9c); encoded only when present, so files without it
        /// still read.
        var failure: KeepAwakeFailure?
    }

    func load() -> KeepAwakeState? {
        envelope()?.state
    }

    /// The failure a stop recorded beside the state; nil when none.
    func loadFailure() -> KeepAwakeFailure? {
        envelope()?.failure
    }

    func save(_ state: KeepAwakeState, failure: KeepAwakeFailure? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelope = Envelope(version: Self.currentVersion, state: state, failure: failure)
        try KeepAwakeCoding.encode(envelope).write(to: url, options: .atomic)
    }

    private func envelope() -> Envelope? {
        guard let data = try? Data(contentsOf: url),
              let envelope = KeepAwakeCoding.decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion
        else { return nil }
        return envelope
    }
}
