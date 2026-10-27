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
        /// A `pmset sleepnow` the daemon still owes (review C4, whole-branch W1), so a restart
        /// pays it; encoded only when true, so files without it still read and owe nothing.
        var sleepOwed: Bool?
        /// The daemon set the flag, or may have, and never saw it read clear since (reviewer
        /// V3): the next start clears it as its own. Encoded only when true, so files without
        /// it still read and own nothing.
        var ownsFlag: Bool?
    }

    func load() -> KeepAwakeState? {
        envelope()?.state
    }

    /// The failure a stop recorded beside the state; nil when none.
    func loadFailure() -> KeepAwakeFailure? {
        envelope()?.failure
    }

    /// Whether a sleep was owed when the file was written; false without a file.
    func loadSleepOwed() -> Bool {
        envelope()?.sleepOwed ?? false
    }

    /// Whether the daemon owned the flag when the file was written; false without a file.
    func loadOwnsFlag() -> Bool {
        envelope()?.ownsFlag ?? false
    }

    func save(_ state: KeepAwakeState, failure: KeepAwakeFailure? = nil, sleepOwed: Bool = false, ownsFlag: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelope = Envelope(
            version: Self.currentVersion,
            state: state,
            failure: failure,
            sleepOwed: sleepOwed ? true : nil,
            ownsFlag: ownsFlag ? true : nil
        )
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
