import Foundation

/// What a tool call is about, in two sizes: a one-line headline for rows and
/// banners, and the full text behind it for the row's expanded block. Lives in
/// memory only — it is derived from `tool_input`, which is never persisted.
struct ToolSummary: Equatable, Sendable {
    /// One line, ≤ 80 characters, whitespace collapsed. Shown in rows and banners.
    let headline: String
    /// Multi-line, ≤ 4096 characters, original whitespace. nil when the headline says it all.
    let detail: String?
    let attention: AgentAttention?
}

/// A tool call that *is* the thing the user has to answer: the agent asked a
/// question, or a plan is waiting for approval. Neither produces a
/// `PermissionRequest` and neither can be answered from Omelette — the answer has
/// to be typed in the terminal, so these carry no Allow / Deny.
enum AgentAttention: Equatable, Sendable, Codable {
    case question(count: Int, multiSelect: Bool)
    case plan
}

enum AgentToolSummary {
    /// One row line. A longer headline is cut to 79 characters plus "…".
    static let maxHeadlineLength = 80
    /// The expanded block. A longer detail is cut to 4095 characters plus "…".
    static let maxDetailLength = 4096
    /// An MCP tool's arguments have no shape we know, so its detail is a compact
    /// JSON of the whole input — kept short, because it is a debugging aid.
    static let maxMCPDetailLength = 1024

    /// nil when the tool is unknown, the input lacks the key the rule reads, or
    /// everything it carries is blank.
    static func make(toolName: String?, toolInput: [String: Any]?) -> ToolSummary? {
        guard let toolName, !toolName.isEmpty, let toolInput else { return nil }
        switch toolName {
        case "Bash":
            return bash(toolInput)
        case "Edit", "Write", "MultiEdit", "Read":
            return file(verb: toolName, path: toolInput["file_path"] as? String)
        case "NotebookEdit":
            return file(verb: toolName, path: toolInput["notebook_path"] as? String)
        case "Grep", "Glob":
            guard let pattern = collapse(toolInput["pattern"] as? String), !pattern.isEmpty else { return nil }
            return plain(headline: "\(toolName) \(pattern)", detail: nil)
        case "WebFetch", "WebSearch":
            return web(toolInput)
        case "AskUserQuestion":
            return question(toolInput)
        case "ExitPlanMode":
            return plan(toolInput)
        default:
            if let parts = mcpParts(toolName) { return mcp(parts, toolInput) }
            return plain(headline: collapse(toolInput["description"] as? String) ?? "", detail: nil)
        }
    }

    // MARK: - Rules

    /// The tool's own description first — it is a sentence someone wrote for a
    /// human — with the command underneath. Never "Bash: …": the tool name is
    /// already the banner's subtitle and the row's label.
    private static func bash(_ input: [String: Any]) -> ToolSummary? {
        let command = input["command"] as? String ?? ""
        let description = collapse(input["description"] as? String) ?? ""
        let headline = description.isEmpty ? (collapse(command) ?? "") : description
        return plain(headline: headline, detail: command)
    }

    /// "Edit WalletView.swift" — the verb is the tool, and the file is the part a
    /// person recognises. The whole path is one click away.
    private static func file(verb: String, path: String?) -> ToolSummary? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return plain(headline: "\(verb) \(name.isEmpty ? path : name)", detail: path)
    }

    /// "docs.example.com/hooks/reference" reads as a place; the whole URL is a line
    /// of percent-escapes. WebSearch has no URL at all, only a query.
    private static func web(_ input: [String: Any]) -> ToolSummary? {
        if let raw = collapse(input["url"] as? String), !raw.isEmpty {
            return plain(headline: shortURL(raw), detail: raw)
        }
        guard let query = collapse(input["query"] as? String), !query.isEmpty else { return nil }
        return plain(headline: query, detail: nil)
    }

    /// Host plus path, without the scheme or the query string. A URL we cannot
    /// parse is shown as it arrived — better a long line than a blank row.
    static func shortURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host else { return raw }
        let path = components.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    /// The agent asked something. The headline is the first question, the detail is
    /// every question with its options — the same list the terminal is showing.
    private static func question(_ input: [String: Any]) -> ToolSummary? {
        let questions = (input["questions"] as? [[String: Any]]) ?? []
        let first = questions.compactMap { collapse($0["question"] as? String) }.first(where: { !$0.isEmpty }) ?? ""
        let multiSelect = questions.contains { ($0["multiSelect"] as? Bool) == true }
        // A malformed payload still asked *something*: one question is the honest
        // floor, and "0 questions for you" would read as a bug.
        let attention = AgentAttention.question(count: max(1, questions.count), multiSelect: multiSelect)

        let headline: String
        if questions.count > 1 {
            headline = first.isEmpty ? "\(questions.count) questions for you" : "\(questions.count) questions: \(first)"
        } else {
            headline = first.isEmpty ? "Question for you" : "Question: \(first)"
        }

        var blocks: [String] = []
        for entry in questions {
            let text = collapse(entry["question"] as? String) ?? ""
            let labels = (entry["options"] as? [[String: Any]] ?? [])
                .compactMap { collapse($0["label"] as? String) }
                .filter { !$0.isEmpty }
            var lines: [String] = text.isEmpty ? [] : [text]
            lines.append(contentsOf: labels.map { "• \($0)" })
            if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
        }
        return ToolSummary(
            headline: cap(headline, maxHeadlineLength),
            detail: blocks.isEmpty ? nil : cap(blocks.joined(separator: "\n\n"), maxDetailLength),
            attention: attention
        )
    }

    /// A plan waiting for approval. Its first real line is its title, so that is the
    /// headline; the plan itself is the detail.
    private static func plan(_ input: [String: Any]) -> ToolSummary? {
        let text = input["plan"] as? String ?? ""
        let title = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { titleLine(String($0)) }
            .first(where: { !$0.isEmpty }) ?? ""
        let headline = title.isEmpty ? "Plan ready for review" : "Plan ready for review: \(title)"
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ToolSummary(
            headline: cap(headline, maxHeadlineLength),
            detail: hasText ? cap(text, maxDetailLength) : nil,
            attention: .plan
        )
    }

    /// A markdown heading is a title, not a row of hashes: "## The plan" reads as
    /// "The plan".
    private static func titleLine(_ line: String) -> String {
        collapse(String(line.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" }))) ?? ""
    }

    /// `mcp__orion_gemini__gemini_research` → server "orion_gemini", tool
    /// "gemini_research". nil when the name is not an MCP one.
    static func mcpParts(_ toolName: String) -> (server: String, tool: String)? {
        let parts = toolName.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return nil }
        let tool = parts.dropFirst(2).joined(separator: "__")
        guard !tool.isEmpty else { return nil }
        return (parts[1], tool)
    }

    /// "Notion", "Orion gemini". Underscores are how these names are spelled, not
    /// how they are read; only the first letter is raised, because the rest may
    /// already carry capitals the author meant.
    static func mcpServerName(_ server: String) -> String {
        let words = server.replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return words }
        return first.uppercased() + words.dropFirst()
    }

    private static func mcp(_ parts: (server: String, tool: String), _ input: [String: Any]) -> ToolSummary? {
        let tool = parts.tool.replacingOccurrences(of: "_", with: " ")
        let headline = "\(mcpServerName(parts.server)): \(tool)"
        return ToolSummary(headline: cap(headline, maxHeadlineLength), detail: compactJSON(input), attention: nil)
    }

    /// Sorted keys so the same input always produces the same line — a detail that
    /// reshuffles itself between two events looks like a change that never happened.
    private static func compactJSON(_ input: [String: Any]) -> String? {
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return cap(text, maxMCPDetailLength)
    }

    // MARK: - Shared

    /// A headline is one line: a multi-line shell command must not break the row.
    private static func collapse(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// nil when there is no headline; the detail is dropped when it only repeats it,
    /// which is what keeps the row's chevron off a one-word command.
    private static func plain(headline: String, detail: String?) -> ToolSummary? {
        let headline = cap(headline, maxHeadlineLength)
        guard !headline.isEmpty else { return nil }
        let body = detail.map { cap($0, maxDetailLength) } ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolSummary(
            headline: headline,
            detail: trimmed.isEmpty || trimmed == headline ? nil : body,
            attention: nil
        )
    }

    private static func cap(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
