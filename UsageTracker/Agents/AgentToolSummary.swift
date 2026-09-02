import Foundation

/// One line describing what a tool call is about: "Bash: xcodegen generate",
/// "Edit: WalletView.swift", "Grep: usageStatusColor". Lives in memory only — it is
/// derived from `tool_input`, which is never persisted.
enum AgentToolSummary {
    /// Length of the detail part; a longer detail is cut to 79 characters plus "…".
    static let maxDetailLength = 80

    /// nil when the tool is unknown, the input lacks the relevant key, or the detail is blank.
    static func make(toolName: String?, toolInput: [String: Any]?) -> String? {
        guard let toolName, !toolName.isEmpty, let toolInput else { return nil }
        guard let raw = detail(toolName: toolName, toolInput: toolInput) else { return nil }
        // Multi-line shell commands must not break the single-row UI.
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return "\(toolName): \(cap(collapsed))"
    }

    private static func detail(toolName: String, toolInput: [String: Any]) -> String? {
        switch toolName {
        case "Bash":
            return toolInput["command"] as? String
        case "Edit", "Write", "Read", "MultiEdit":
            return (toolInput["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "NotebookEdit":
            return (toolInput["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            return toolInput["pattern"] as? String
        default:
            return nil
        }
    }

    private static func cap(_ detail: String) -> String {
        guard detail.count > maxDetailLength else { return detail }
        return String(detail.prefix(maxDetailLength - 1)) + "…"
    }
}
