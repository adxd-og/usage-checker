import Foundation

/// The pets the app can draw (notch-island spec 2026-10-29 § 3.5): every folder under `Pets/`
/// whose `pet.json` passes the contract check, read once into memory, so a palette change later
/// recolours from memory and never re-reads a file. A folder that fails stays out of the pets,
/// with its check kept for the bundle test and the log.
struct PetLibrary: Equatable, Sendable {
    /// Every manifest that passed, by id (= its folder's name).
    let manifests: [String: PetManifest]
    /// Every folder's check, by folder name, passed or not.
    let checks: [String: PetManifestCheck]

    static let empty = PetLibrary(manifests: [:], checks: [:])

    /// The ids of the pets that passed, alphabetical.
    var animalIDs: [String] { manifests.keys.sorted() }

    /// Reads `<directory>/<folder>/pet.json` for every folder in `directory`; plain files and
    /// hidden entries are skipped. No such directory gives `empty`.
    static func load(from directory: URL) -> PetLibrary {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return .empty }
        var manifests: [String: PetManifest] = [:]
        var checks: [String: PetManifestCheck] = [:]
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folder = entry.lastPathComponent
            let check: PetManifestCheck
            if let data = try? Data(contentsOf: entry.appendingPathComponent(PetContract.fileName)) {
                check = PetManifestValidator.check(data, folder: folder)
            } else {
                check = PetManifestCheck(issues: [.noManifest], notes: [], manifest: nil)
            }
            checks[folder] = check
            if let manifest = check.manifest {
                manifests[folder] = manifest
            } else {
                NSLog("[UT] pet %@ left out: %@", folder, check.issues.map(\.description).joined(separator: "; "))
            }
        }
        return PetLibrary(manifests: manifests, checks: checks)
    }
}
