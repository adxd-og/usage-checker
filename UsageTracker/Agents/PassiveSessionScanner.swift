import Foundation

/// Sessions read straight from the CLIs' own logs, for when no hooks are installed —
/// and as a safety net when they are. Everything here is approximate: a file's
/// modification time says bytes were appended, not what the agent is waiting for, so
/// these sessions never claim `needsYou` and are flagged `isApproximate`.
///
/// Stateless on purpose: `AppState` calls it from a background task on every poll
/// tick, and the store owns all the memory.
enum PassiveSessionScanner {
    /// How much of a log we are willing to read looking for `cwd` / `session_meta`.
    /// Claude puts `cwd` on its first message record (~5 KB into a real transcript);
    /// Codex's `session_meta` line is ~19 KB because it embeds the base instructions.
    /// 64 KB clears both and can never pull in a multi-megabyte tool-result line.
    private static let headBytes = 64 * 1024
    /// Upper bound on JSON parses per file — a pathological log of tiny lines must not
    /// turn a poll tick into thousands of deserialisations.
    private static let maxHeadLines = 200

    static func scan(
        claudeProjects: URL,
        codexSessions: URL,
        now: Date = Date(),
        recentWindow: TimeInterval = 30 * 60,
        workingWindow: TimeInterval = 30
    ) -> [AgentSession] {
        scanClaude(root: claudeProjects, now: now, recentWindow: recentWindow, workingWindow: workingWindow)
            + scanCodex(root: codexSessions, now: now, recentWindow: recentWindow, workingWindow: workingWindow)
    }

    // MARK: - Claude Code

    /// `~/.claude/projects/<slug>/<session_id>.jsonl` — the transcript is named after
    /// the session, which is the same id the hooks send, so a passive row is replaced
    /// by the hook row instead of duplicating it.
    ///
    /// Only files whose grandparent is the root count. Below a project directory sits
    /// `<session_id>/subagents/**.jsonl` (and `subagents/workflows/*/journal.jsonl`) —
    /// side-transcripts of subagents, which the spec ignores, and which outnumber real
    /// transcripts by more than ten to one. The enumerator is pruned there too, so the
    /// per-minute scan never walks that tree.
    private static func scanClaude(
        root: URL, now: Date, recentWindow: TimeInterval, workingWindow: TimeInterval
    ) -> [AgentSession] {
        // Symlinks resolved on both sides: the temp dir the tests use is
        // /var/folders/… which is a link to /private/var/folders/….
        let rootPath = root.resolvingSymlinksInPath().path
        var sessions: [AgentSession] = []
        forEachRecentLog(root: root, now: now, recentWindow: recentWindow, descendInto: { directory in
            directory.deletingLastPathComponent().resolvingSymlinksInPath().path == rootPath
        }) { url, mtime in
            guard url.deletingLastPathComponent().deletingLastPathComponent()
                .resolvingSymlinksInPath().path == rootPath else { return }
            let sessionID = url.deletingPathExtension().lastPathComponent
            // Claude names transcripts after the session uuid; anything else at
            // this level (a stray export, a tool's side file) is not a session.
            guard UUID(uuidString: sessionID) != nil else { return }
            let cwd = firstString(forKey: "cwd", in: url)
            sessions.append(makeSession(
                source: .claude,
                sessionID: sessionID,
                cwd: cwd,
                fallbackSlug: url.deletingLastPathComponent().lastPathComponent,
                mtime: mtime, now: now, workingWindow: workingWindow
            ))
        }
        return sessions
    }

    // MARK: - Codex

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl`. The uuid in the
    /// name is the thread id, and the file's first line (`session_meta`) repeats it
    /// alongside `cwd` — we prefer the line because it is authoritative and we are
    /// reading the head for `cwd` anyway.
    private static func scanCodex(
        root: URL, now: Date, recentWindow: TimeInterval, workingWindow: TimeInterval
    ) -> [AgentSession] {
        var sessions: [AgentSession] = []
        forEachRecentLog(root: root, now: now, recentWindow: recentWindow, descendInto: { _ in true }) { url, mtime in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("rollout-") else { return }
            let head = codexHead(url)
            guard let sessionID = head.sessionID ?? codexSessionID(fileName: name) else { return }
            sessions.append(makeSession(
                source: .codex,
                sessionID: sessionID,
                cwd: head.cwd,
                fallbackSlug: nil,
                mtime: mtime, now: now, workingWindow: workingWindow
            ))
        }
        return sessions
    }

    /// The thread id is the trailing 36 characters of the file name:
    /// `rollout-2026-08-06T14-30-14-019fd6d6-94a9-7611-a007-3c094955e537`.
    static func codexSessionID(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-") else { return nil }
        let tail = String(fileName.suffix(36))
        guard tail.count == 36, UUID(uuidString: tail) != nil else { return nil }
        return tail
    }

    private static func codexHead(_ url: URL) -> (sessionID: String?, cwd: String?) {
        for line in headLines(of: url) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any]
            let id = (payload?["session_id"] as? String) ?? (payload?["id"] as? String)
            let cwd = (payload?["cwd"] as? String) ?? (object["cwd"] as? String)
            if id != nil || cwd != nil { return (nonEmpty(id), nonEmpty(cwd)) }
        }
        return (nil, nil)
    }

    // MARK: - Shared

    private static func makeSession(
        source: AgentSource, sessionID: String, cwd: String?, fallbackSlug: String?,
        mtime: Date, now: Date, workingWindow: TimeInterval
    ) -> AgentSession {
        // "Working" is the only thing an mtime can tell us: the CLI wrote to this log
        // moments ago. Anything older is just "open".
        let state: AgentState = mtime >= now.addingTimeInterval(-workingWindow) ? .working : .idle
        return AgentSession(
            sessionID: sessionID,
            source: source,
            projectName: projectName(cwd: cwd, fallbackSlug: fallbackSlug),
            cwd: cwd,
            state: state,
            activity: nil,
            stateSince: mtime,
            lastEventAt: mtime,
            startedAt: mtime,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
            isApproximate: true,
            turns: 0,
            needsYouCount: 0
        )
    }

    private static func projectName(cwd: String?, fallbackSlug: String?) -> String {
        if let cwd, !cwd.isEmpty { return ProjectName.display(path: cwd) }
        if let fallbackSlug, !fallbackSlug.isEmpty { return ProjectName.decode(slug: fallbackSlug) }
        return "Unknown project"
    }

    /// Walks `root` for `.jsonl` files modified inside `recentWindow`. `descendInto`
    /// decides whether a directory is worth entering, which is what keeps the Claude
    /// scan out of the subagents trees.
    private static func forEachRecentLog(
        root: URL, now: Date, recentWindow: TimeInterval,
        descendInto: (URL) -> Bool,
        body: (URL, Date) -> Void
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-recentWindow)
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
            )
            if values?.isDirectory == true {
                if !descendInto(url) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            guard let mtime = values?.contentModificationDate, mtime >= cutoff else { continue }
            body(url, mtime)
        }
    }

    private static func firstString(forKey key: String, in url: URL) -> String? {
        for line in headLines(of: url) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Complete lines from the first `headBytes` of a log. A trailing partial line is
    /// dropped: a poll can land mid-write, and half a JSON object is not data.
    private static func headLines(of url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else { return [] }

        var lines: [Data] = []
        var lineStart = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                if index > lineStart { lines.append(Data(data[lineStart..<index])) }
                lineStart = data.index(after: index)
                if lines.count >= maxHeadLines { return lines }
            }
            index = data.index(after: index)
        }
        return lines
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
