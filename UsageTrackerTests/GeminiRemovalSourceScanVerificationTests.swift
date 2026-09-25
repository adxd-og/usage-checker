import XCTest
@testable import Omelette

/// Independent verification of the liquid-glass redesign spec, P8 row (line 238) and
/// the owner's binding 2026-09-26 clarification: only the Gemini CLI provider goes —
/// `GeminiProvider`, `GeminiErrorCopy`, the `geminiProviderEnabled` key, the `gemini`
/// service id, the Settings deprecated-row mechanism, the gemini cases across the
/// coordinator / `DashboardState.costSource` / `HistoryCopy.quotaOnlyNote` / popover
/// help / widget `ProviderChoice`, the `ProviderIcon-gemini` asset and README lines.
/// Everything Gemini *inside* Antigravity stays (the `antigravity_gemini` "Gemini
/// models" bucket, its copy, models.dev "google" prices), and so do the `orion-gemini`
/// fleet names, which are a different feature entirely.
///
/// This scans the actual tracked sources with `git grep`, so it catches anything the
/// unit tests above cannot reach (dead code no test calls, string literals in views,
/// asset catalogs) rather than trusting the diff's own account of itself.
final class GeminiRemovalSourceScanVerificationTests: XCTestCase {
    /// Identifiers that must never appear again, anywhere in the scanned tree,
    /// regardless of which file or how the surrounding line reads.
    private static let neverAgain = ["GeminiProvider", "GeminiErrorCopy", "geminiProviderEnabled", "ProviderIcon-gemini"]

    /// Every other match is allowed only if it falls into one of these buckets — all of
    /// them things the owner's clarification explicitly keeps. Checked case-insensitively
    /// except where noted.
    private static let allowedIfContainsAny = [
        "gemini models",       // Antigravity's "Gemini models" quota pool (label and bucket id)
        "antigravity_gemini",  // its bucket id
        ".gemini/antigravity", // Antigravity's own install/CLI footprint under ~/.gemini
        "orion-gemini",        // the fleet's Gemini research unit, an unrelated feature
        "orion_gemini",        // same, MCP tool-name spelling
        "orion gemini",        // same, title-cased display form
        "gemini_research",     // the fleet tool's own name, doc-commented on its own continuation line
        "gemini cli oauth",    // AntigravityProvider's own doc comment on what it replaced
        "gemini quotas",       // AntigravityProvider's own doc comment
        "gemini-3.1-pro-preview", // a models.dev model id in a doc comment (ModelPricing)
        "google the gemini",   // ModelsDevPricing's doc comment on the "google" price family
    ]

    private static func repoRoot() throws -> URL {
        // This file lives at "<repo>/UsageTrackerTests/<name>.swift" — two path
        // components up from its own compile-time path is the repo root, independent of
        // the machine's $HOME or the test host's current directory.
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        return url
    }

    private struct GrepLine {
        let path: String
        let text: String
    }

    /// Runs `git grep -ni gemini` over exactly the directories the brief names, scoped
    /// to the given repo root, and parses `path:line:text` output. Exit code 1 means "no
    /// matches", which is success, not failure; anything above 1 is a real git error.
    private func grepGeminiMentions(in repo: URL) throws -> [GrepLine] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "grep", "-ni", "gemini", "--",
            "UsageTracker", "CLICore", "CLI", "HookHelper", "UsageTrackerWidget", "SharedUI", "SharedAssets",
        ]
        process.currentDirectoryURL = repo
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertLessThanOrEqual(process.terminationStatus, 1, "git grep itself failed (status \(process.terminationStatus))")

        let output = String(decoding: data, as: UTF8.self)
        guard !output.isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { rawLine in
            // "path:lineNumber:text" — split on the first two colons only, since the
            // matched text itself may contain colons.
            let parts = rawLine.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return GrepLine(path: String(parts[0]), text: String(parts[2]))
        }
    }

    func testNoTrackedSourceOutsideAntigravityFleetAndModelsDevMentionsGemini() throws {
        let repo = try Self.repoRoot()
        let matches = try grepGeminiMentions(in: repo)
        XCTAssertFalse(matches.isEmpty, "sanity: Antigravity's own Gemini-pool lines should still match")

        var unexplained: [GrepLine] = []
        for match in matches {
            for banned in Self.neverAgain {
                XCTAssertFalse(
                    match.text.contains(banned),
                    "\(match.path): \(banned) must never appear again — \(match.text)"
                )
            }
            let lowered = match.text.lowercased()
            let allowed = Self.allowedIfContainsAny.contains { lowered.contains($0) }
            if !allowed { unexplained.append(match) }
        }

        XCTAssertTrue(
            unexplained.isEmpty,
            "unexplained \"gemini\" mention(s) outside the allowed patterns:\n"
                + unexplained.map { "\($0.path): \($0.text)" }.joined(separator: "\n")
        )
    }
}
