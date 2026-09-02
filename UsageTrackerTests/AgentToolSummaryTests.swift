import XCTest
@testable import Omelette

final class AgentToolSummaryTests: XCTestCase {
    func testBashUsesTheCommand() {
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "xcodegen generate", "description": "Regenerate"]),
                       "Bash: xcodegen generate")
    }

    func testFileToolsUseTheBasename() {
        let input: [String: Any] = ["file_path": "/Users/me/Desktop/Usage tracker/UsageTracker/UI/PopoverView.swift", "old_string": "a", "new_string": "b"]
        XCTAssertEqual(AgentToolSummary.make(toolName: "Edit", toolInput: input), "Edit: PopoverView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Write", toolInput: ["file_path": "/tmp/WalletView.swift", "content": "…"]), "Write: WalletView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Read", toolInput: ["file_path": "/tmp/PopoverView.swift"]), "Read: PopoverView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "MultiEdit", toolInput: ["file_path": "/tmp/A.swift", "edits": []]), "MultiEdit: A.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "NotebookEdit", toolInput: ["notebook_path": "/tmp/n.ipynb"]), "NotebookEdit: n.ipynb")
    }

    func testSearchToolsUseThePattern() {
        XCTAssertEqual(AgentToolSummary.make(toolName: "Grep", toolInput: ["pattern": "usageStatusColor", "path": "/tmp"]), "Grep: usageStatusColor")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Glob", toolInput: ["pattern": "**/*.swift"]), "Glob: **/*.swift")
    }

    func testNoDetailMeansNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": "https://example.com"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: nil))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "   \n"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": 42]))
        XCTAssertNil(AgentToolSummary.make(toolName: nil, toolInput: ["command": "ls"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "", toolInput: ["command": "ls"]))
    }

    func testWhitespaceCollapsesToOneLine() {
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "  cd /tmp &&\n\n  ls   -la\t"]),
                       "Bash: cd /tmp && ls -la")
    }

    func testDetailIsCutAt80CharactersWithAnEllipsis() throws {
        let command = String(repeating: "x", count: 200)
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command]))
        let detail = String(summary.dropFirst("Bash: ".count))
        XCTAssertEqual(detail.count, AgentToolSummary.maxDetailLength)
        XCTAssertTrue(detail.hasSuffix("…"))
        XCTAssertEqual(String(detail.dropLast()), String(repeating: "x", count: 79))
    }

    func testExactly80CharactersIsNotCut() throws {
        let command = String(repeating: "y", count: 80)
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command]), "Bash: \(command)")
    }
}
