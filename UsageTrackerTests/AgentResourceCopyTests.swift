import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Where it shows and Decisions 1–2: the island's suffix
/// "212% · 3.4 GB" (the percent spelled as `PercentDisplay` spells it, no space) from 50 % CPU
/// (per core, whatever the scale) or 4 GB up; the Agents tab's figures for every measured
/// session; memory in MB or GB; CPU per core (100 % is one core) or for the whole Mac (the
/// per-core figure over the active cores, never above 100).
final class AgentResourceCopyTests: XCTestCase {
    private typealias F = AgentProcessFixture
    private typealias Figures = AgentResourceRules.Figures
    /// 3.4 GB in binary units: below the island's 4 GB.
    private let large = 3_650_722_202
    /// 4.7 GB: above it.
    private let huge = 5_046_586_573

    func testTheScalesAreNamedPerCoreAndWholeMac() {
        XCTAssertEqual(AgentCPUScale.allCases, [.perCore, .wholeMac])
        XCTAssertEqual(AgentCPUScale.allCases.map(\.displayName), ["Per core", "Whole Mac"])
        XCTAssertEqual(AgentCPUScale.allCases.map(\.rawValue), ["perCore", "wholeMac"])
    }

    func testPerCoreIsActivityMonitorsFigureSpelledAsEveryPercentInTheIsland() {
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 212.4, scale: .perCore, cores: 10), "212%")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 49.5, scale: .perCore, cores: 10), "50%")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 0.4, scale: .perCore, cores: 10), "0%")
    }

    func testWholeMacDividesByTheActiveCoresAndNeverPassesAHundred() {
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 212.4, scale: .wholeMac, cores: 10), "21%")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 212.4, scale: .wholeMac, cores: 2), "100%")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 50, scale: .wholeMac, cores: 0), "50%", "no cores reported reads as one")
    }

    func testMemoryIsInMegabytesBelowAGigabyteThenInGigabytes() {
        XCTAssertEqual(AgentResourceCopy.memoryText(bytes: 634 * F.mb), "634 MB")
        XCTAssertEqual(AgentResourceCopy.memoryText(bytes: large), "3.4 GB")
        XCTAssertEqual(AgentResourceCopy.memoryText(bytes: 1_073_322_394), "1.0 GB", "1023.6 MB rounds up to a gigabyte")
        XCTAssertEqual(AgentResourceCopy.memoryText(bytes: 1_073_741_824), "1.0 GB")
        XCTAssertEqual(AgentResourceCopy.memoryText(bytes: 0), "0 MB")
    }

    func testTheIslandSuffixShowsFromFiftyPercentOrFourGigabytes() {
        XCTAssertEqual(AgentResourceCopy.islandSuffix(Figures(cpuPercent: 212.4, memoryBytes: large), scale: .perCore, cores: 10), "212% · 3.4 GB")
        XCTAssertEqual(AgentResourceCopy.islandSuffix(Figures(cpuPercent: 50, memoryBytes: 634 * F.mb), scale: .perCore, cores: 10), "50% · 634 MB")
        XCTAssertEqual(AgentResourceCopy.islandSuffix(Figures(cpuPercent: 12, memoryBytes: 4_294_967_296), scale: .perCore, cores: 10), "12% · 4.0 GB")
        XCTAssertNil(AgentResourceCopy.islandSuffix(Figures(cpuPercent: 49.9, memoryBytes: 4_294_967_295), scale: .perCore, cores: 10), "just under both thresholds")
        XCTAssertNil(
            AgentResourceCopy.islandSuffix(Figures(cpuPercent: 3.2, memoryBytes: 2533 * F.mb), scale: .perCore, cores: 10),
            "a waiting claude at 2533 MB, as measured 2026-11-19, stays quiet"
        )
        XCTAssertNil(AgentResourceCopy.islandSuffix(nil, scale: .perCore, cores: 10))
    }

    func testTheThresholdStaysOnThePerCoreScale() {
        XCTAssertEqual(
            AgentResourceCopy.islandSuffix(Figures(cpuPercent: 60, memoryBytes: 100 * F.mb), scale: .wholeMac, cores: 10),
            "6% · 100 MB", "60 % per core is busy, whatever the scale prints"
        )
        XCTAssertNil(AgentResourceCopy.islandSuffix(Figures(cpuPercent: 45, memoryBytes: 100 * F.mb), scale: .wholeMac, cores: 10))
    }

    func testTheFirstReadingShowsMemoryOnly() {
        XCTAssertEqual(AgentResourceCopy.islandSuffix(Figures(cpuPercent: nil, memoryBytes: huge), scale: .perCore, cores: 10), "4.7 GB")
        XCTAssertNil(AgentResourceCopy.islandSuffix(Figures(cpuPercent: nil, memoryBytes: large), scale: .perCore, cores: 10))
        XCTAssertEqual(AgentResourceCopy.dashboardText(Figures(cpuPercent: nil, memoryBytes: 634 * F.mb), scale: .perCore, cores: 10), "634 MB")
    }

    func testTheAgentsTabShowsBothFiguresForEveryMeasuredSession() {
        XCTAssertEqual(AgentResourceCopy.dashboardText(Figures(cpuPercent: 3.2, memoryBytes: 634 * F.mb), scale: .perCore, cores: 10), "3% CPU · 634 MB")
        XCTAssertEqual(AgentResourceCopy.dashboardText(Figures(cpuPercent: 212.4, memoryBytes: large), scale: .wholeMac, cores: 10), "21% CPU · 3.4 GB")
        XCTAssertNil(AgentResourceCopy.dashboardText(nil, scale: .perCore, cores: 10))
    }

    func testANonFiniteOrNegativeCPUReadsAsZero() {
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: .nan, scale: .perCore, cores: 10), "0%")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: .infinity, scale: .wholeMac, cores: 10), "0%")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: -4, scale: .perCore, cores: 10), "0%")
    }
}
