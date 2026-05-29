import Foundation

/// Decodes Claude Code's project-directory slug into something user-readable.
///
/// Claude Code stores sessions at:
///     ~/.claude/projects/<slug>/<session-uuid>.jsonl
/// where `<slug>` is the original absolute project path with every `/` replaced by `-`.
///
/// Slug example: a directory name with leading `-`, sections separated by `-`
/// (the original absolute path had `/` instead).
///
/// We can't perfectly recover spaces from dashes (a folder named "Orion Gate" looks the
/// same as two folders "Orion" and "Gate"), but for display we strip the home prefix
/// and show the last 2 path components — enough context for users to recognize the project.
enum ProjectName {
    static func decode(slug: String) -> String {
        let trimmed = slug.hasPrefix("-") ? String(slug.dropFirst()) : slug
        let tokens = trimmed.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return slug }

        // The slug is lossy: Claude Code turns both "/" and spaces into "-", so a naive
        // "-"→"/" gives "Orion/Gate/mobile/app" for a folder actually named
        // "Orion Gate mobile app". Resolve it against the real filesystem when we can;
        // fall back to the naive split when the project no longer exists on disk.
        let fullPath: String
        if let resolved = resolveOnDisk(tokens) {
            fullPath = "/" + resolved.joined(separator: "/")
        } else {
            fullPath = "/" + tokens.joined(separator: "/")
        }
        return prettify(fullPath, fallback: slug)
    }

    /// Greedily walks the filesystem, at each directory level matching the longest run of
    /// remaining tokens (space-joined) that names an existing subdirectory. Returns the
    /// resolved path components, or nil if any level can't be matched.
    private static func resolveOnDisk(_ tokens: [String]) -> [String]? {
        let fm = FileManager.default
        var components: [String] = []
        var dir = "/"
        var i = 0
        while i < tokens.count {
            var matched = false
            var j = tokens.count
            while j > i {
                let name = tokens[i..<j].joined(separator: " ")
                let candidate = dir + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                    components.append(name)
                    dir = candidate + "/"
                    i = j
                    matched = true
                    break
                }
                j -= 1
            }
            if !matched { return nil }
        }
        return components
    }

    /// Strips the home prefix and a noise parent, then shows the last 1–2 path components.
    private static func prettify(_ fullPath: String, fallback: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var clean = fullPath
        if clean.hasPrefix(home + "/") {
            clean = String(clean.dropFirst(home.count + 1))
        } else if clean.hasPrefix("/") {
            clean = String(clean.dropFirst())
        }

        let noisePrefixes = ["Desktop/", "Documents/", "Developer/", "Projects/", "Code/", "Workspace/"]
        for prefix in noisePrefixes where clean.hasPrefix(prefix) {
            clean = String(clean.dropFirst(prefix.count))
            break
        }

        let parts = clean.split(separator: "/", omittingEmptySubsequences: true)
        if parts.isEmpty { return fallback }
        if parts.count == 1 { return String(parts[0]) }
        return parts.suffix(2).map(String.init).joined(separator: " / ")
    }
}
