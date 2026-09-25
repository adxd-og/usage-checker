import XCTest
@testable import Omelette

/// Independent verification of P0 (liquid-glass redesign spec § Design → Platform
/// floor, § Decisions "Helper deployment targets"): "The deployment target moves to
/// 26.0 for the app, the widget extension and the CLI/hook helpers that ship inside
/// the bundle" and "hook, CLI, widget and tests move to 26.0 with the app". The
/// executor's own `PlatformFloorTests` reads the *built* app and widget bundles'
/// `LSMinimumSystemVersion`; this file instead reads `project.yml` directly — the
/// source of truth `scripts/update_appcast.sh` also reads — so a target that
/// `PlatformFloorTests` does not build-check (HookHelper, CLI, UsageTrackerTests
/// itself) is still covered, and so is the base/package-level setting.
final class PlatformFloorVerificationTests: XCTestCase {
    private func findRepoRoot() throws -> URL {
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<25 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
        }
        throw XCTSkip("could not locate the repo root by walking up from the test bundle")
    }

    private func projectYAML() throws -> String {
        let url = try findRepoRoot().appendingPathComponent("project.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The base `options.deploymentTarget.macOS` and the package-level
    /// `MACOSX_DEPLOYMENT_TARGET` — both apply to every target that does not override
    /// them, so a floor bug here would be invisible to a test that only reads a target
    /// section.
    func testTheBaseAndPackageLevelFloorsAreBoth26() throws {
        let yaml = try projectYAML()
        XCTAssertTrue(yaml.contains("macOS: \"26.0\""), "options.deploymentTarget.macOS must be 26.0")
        XCTAssertTrue(yaml.contains("MACOSX_DEPLOYMENT_TARGET: \"26.0\""), "the package-level setting must be 26.0")
    }

    /// Every named target's explicit `deploymentTarget:` line is 26.0. The Facts
    /// pointer lines name five explicit per-target floors (app, tests, widget, hook,
    /// CLI); this asserts there are exactly five `deploymentTarget:` lines in the file
    /// and every one reads 26.0, so a sixth target added later without the line (and
    /// so silently inheriting some other value) would also be caught by the count.
    func testEveryTargetsExplicitDeploymentTargetIs26() throws {
        let yaml = try projectYAML()
        // The base `options.deploymentTarget:` (line 7) carries no value on its own
        // line — its `macOS: "26.0"` is nested below and covered by the previous test —
        // so only the inline `deploymentTarget: "…"` lines are each target's own floor.
        let targetLines = yaml
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("deploymentTarget: \"") }
        XCTAssertEqual(targetLines.count, 5, "expected one deploymentTarget line per target (app, tests, widget, hook, CLI): \(targetLines)")
        for line in targetLines {
            XCTAssertEqual(line, "deploymentTarget: \"26.0\"", line)
        }
    }

    /// No stray pre-3.0 floor survives anywhere in the file (14.0 or 15.0, the two
    /// values the README's old requirements line and the Facts pointer lines named).
    func testNoTargetOrBaseSettingStillNamesAPre30Floor() throws {
        let yaml = try projectYAML()
        XCTAssertFalse(yaml.contains("\"14.0\""), "a 14.0 deployment floor survives in project.yml")
        XCTAssertFalse(yaml.contains("\"15.0\""), "a 15.0 deployment floor survives in project.yml")
    }
}
