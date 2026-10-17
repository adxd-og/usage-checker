import Foundation

/// Where a git worktree's chats belong (spec 2026-10-16 limit analytics § The tab, item 3:
/// a project's row sums its chats). A chat run in a linked worktree is its repository's
/// work, but its cost log names the worktree's directory: a project of its own that, once
/// the worktree is removed, decodes to nothing anyone recognises. These rules tell a
/// worktree's directory from the same place in the repository's main working tree, and
/// fold a share's chats onto it.
///
/// Paths are strings here, resolved with `realpath(3)`: that gives each name in the form
/// the file system stores it, which is the form both CLIs log as their `cwd` (`getcwd`
/// gives the same), where a `URL` hands back a non-ASCII name decomposed.
enum ProjectWorktrees {}

/// What a directory is, as far as `git worktree` goes.
enum WorktreeLookup: Equatable, Sendable {
    /// Inside a linked worktree; `main` is the same directory in the main working tree, as
    /// the file system has it.
    case linked(main: String)
    /// On disk and in no linked worktree: a main working tree, a submodule, a bare
    /// repository's, or no repository at all.
    case unlinked
    /// Not on disk: a worktree removed since, or not an absolute path.
    case missing
}

/// A directory a session ran in inside a linked worktree, and the same directory in the
/// repository's main working tree.
struct WorktreeLink: Codable, Equatable, Sendable {
    /// As the session's log names it.
    let path: String
    /// As the file system has it.
    let main: String
    /// When a session was last seen running there.
    let seenAt: Date
}

extension ProjectWorktrees {
    /// What `path` is (`git worktree`'s layout). `path` is resolved first (`realpath(3)`):
    /// a symbolic link into a worktree is the worktree's. The nearest `.git` at or above
    /// what it resolves to decides:
    /// - a file reading `gitdir: <dir>` names the worktree's git directory, and that
    ///   directory's `commondir` the repository's (`<repo>/.git/worktrees/<name>` and
    ///   `../..`). The main working tree is the directory holding that `.git`; the answer is
    ///   the place inside it that `path` is inside the worktree. A relative path in either
    ///   file is read from the directory that holds the file, as the file system has it;
    /// - a directory, no `.git` below the root, a git directory with no `commondir` (a
    ///   submodule's) or a common one not named `.git` (a bare repository's): `unlinked`.
    nonisolated static func lookup(_ path: String) -> WorktreeLookup {
        guard path.hasPrefix("/"), let resolved = onDisk(path) else { return .missing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue
        else { return .missing }
        var root = resolved
        while root != "/" {
            var gitIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root + "/.git", isDirectory: &gitIsDirectory) {
                guard !gitIsDirectory.boolValue, let main = mainWorkingTree(of: root) else { return .unlinked }
                return .linked(main: main + String(resolved.dropFirst(root.count)))
            }
            root = parent(of: root)
        }
        return .unlinked
    }

    /// The main working tree a linked worktree's `.git` file leads to, as the file system
    /// has it, or nil. The git directory is followed on disk (`onDisk`) before its
    /// `commondir` is read from it, and so is the common directory before it is checked:
    /// `..` worked out on a path through a symbolic link would climb the link's own
    /// parents, and could land on another repository's `.git`.
    private static func mainWorkingTree(of worktree: String) -> String? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:"),
              let gitDir = onDisk(
                joined(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), to: worktree)
              ),
              let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8),
              let commonDir = onDisk(joined(common.trimmingCharacters(in: .whitespacesAndNewlines), to: gitDir)),
              commonDir.hasSuffix("/.git")
        else { return nil }
        let main = parent(of: commonDir)
        return main == worktree ? nil : main
    }

    /// `path` as the file system has it (`realpath(3)`): links followed, each name in its
    /// stored form. nil when it does not exist.
    private static func onDisk(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The directory holding `path`, which has no trailing "/".
    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// `path`, read from `directory` when relative. Its `.` and `..` are left to
    /// `realpath(3)`, which works them out on disk.
    private static func joined(_ path: String, to directory: String) -> String {
        path.hasPrefix("/") ? path : directory + "/" + path
    }

    /// Claude Code's name for a directory's project folder (`~/.claude/projects/<slug>`):
    /// every UTF-16 unit but an ASCII letter or digit becomes "-". On this Mac all 48
    /// project folders whose transcripts carry a `cwd` are named so.
    nonisolated static func claudeSlug(_ path: String) -> String {
        String(decoding: path.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return unit
            default: return 0x2D
            }
        }, as: UTF16.self)
    }

    /// Codex's: the rollout's `cwd` percent-encoded but for letters and digits, as
    /// `CodexUsageAggregator` keys a chat's project.
    nonisolated static func codexSlug(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }

    /// Each link as `serviceID`'s cost log names it: the worktree directory's slug → the
    /// main directory's.
    /// - The worktree directory is folded as its link names it and in its composed and
    ///   decomposed forms: a log keeps whichever form its CLI was handed. The destination
    ///   is the main directory as the file system has it, the form a session there logs.
    /// - A slug that links put on different repositories folds nowhere: which one a chat
    ///   under it ran in cannot be told. Links sharing a slug and a repository fold.
    /// - None for a provider whose chats the Limits tab does not measure.
    nonisolated static func folds(_ links: [WorktreeLink], serviceID: String) -> [String: String] {
        let slug: (String) -> String
        switch serviceID {
        case "claude": slug = claudeSlug
        case "codex": slug = codexSlug
        default: return [:]
        }
        var destinations: [String: Set<String>] = [:]
        for link in links {
            let main = slug(link.main)
            let forms = [
                link.path,
                link.path.precomposedStringWithCanonicalMapping,
                link.path.decomposedStringWithCanonicalMapping,
            ]
            for form in Set(forms.map(slug)) {
                destinations[form, default: []].insert(main)
            }
        }
        return destinations.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}

extension LimitShareRules {
    /// `share` with each chat whose project `folds` names moved to the project it folds
    /// onto, and the projects summed again (spec § The tab, item 3): a worktree's chats
    /// count under its repository in Projects, under its name in Chats, and in its colour
    /// on the timeline. The chats keep their points, order and bins.
    nonisolated static func foldingProjects(_ share: LimitShare, into folds: [String: String]) -> LimitShare {
        guard share.chats.contains(where: { folds[$0.projectSlug] != nil }) else { return share }
        let chats = share.chats.map { chat in
            ChatShare(
                id: chat.id, title: chat.title, projectSlug: folds[chat.projectSlug] ?? chat.projectSlug,
                points: chat.points, cost: chat.cost, tokens: chat.tokens, lastAt: chat.lastAt
            )
        }
        return LimitShare(
            window: share.window, percent: share.percent, chats: chats, projects: projectShares(chats),
            outside: share.outside, bins: share.bins, cost: share.cost, tokens: share.tokens, price: share.price,
            costByModel: share.costByModel, unbinnedOutside: share.unbinnedOutside, earlier: share.earlier
        )
    }
}
