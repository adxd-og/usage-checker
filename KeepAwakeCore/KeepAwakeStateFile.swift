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
    }

    func load() -> KeepAwakeState? {
        guard let data = try? Data(contentsOf: url),
              let envelope = KeepAwakeCoding.decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion
        else { return nil }
        return envelope.state
    }

    func save(_ state: KeepAwakeState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try KeepAwakeCoding.encode(Envelope(version: Self.currentVersion, state: state)).write(to: url, options: .atomic)
    }
}
