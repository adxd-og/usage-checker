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
        let fullPath = "/" + trimmed.replacingOccurrences(of: "-", with: "/")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var clean = fullPath
        if clean.hasPrefix(home + "/") {
            clean = String(clean.dropFirst(home.count + 1))
        } else if clean.hasPrefix("/") {
            clean = String(clean.dropFirst())
        }

        // Drop common parent dirs that don't help disambiguate.
        let noisePrefixes = ["Desktop/", "Documents/", "Developer/", "Projects/", "Code/", "Workspace/"]
        for prefix in noisePrefixes where clean.hasPrefix(prefix) {
            clean = String(clean.dropFirst(prefix.count))
            break
        }

        let parts = clean.split(separator: "/", omittingEmptySubsequences: true)
        if parts.isEmpty { return slug }
        if parts.count == 1 { return String(parts[0]) }
        let lastTwo = parts.suffix(2).map(String.init)
        return lastTwo.joined(separator: " / ")
    }
}
