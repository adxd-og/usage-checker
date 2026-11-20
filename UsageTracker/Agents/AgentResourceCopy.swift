import Foundation

/// The CPU scale the island and the Agents tab print (spec 2026-11-19 agent resources,
/// Decision 2). The 50 % threshold and the wire's `cpuPercent` stay per core whichever is chosen.
enum AgentCPUScale: String, CaseIterable, Identifiable, Sendable {
    /// 100 % is one core, as Activity Monitor counts. The default.
    case perCore
    /// 0–100 %: the per-core figure over `ProcessInfo.activeProcessorCount`, never above 100.
    case wholeMac

    var id: String { rawValue }

    /// The Settings menu's words, as the spec names the two scales.
    var displayName: String {
        switch self {
        case .perCore: return "Per core"
        case .wholeMac: return "Whole Mac"
        }
    }
}

/// Every word and figure agent resources print (spec 2026-11-19 agent resources § Where it
/// shows): the island's suffix, the Agents tab's figures, and the CPU and memory texts both use.
enum AgentResourceCopy {
    /// The island's suffix shows from here up, per core whatever the scale (Decisions 1, 2) …
    static let islandCPUThreshold: Double = 50
    /// … or from four gigabytes of memory up: waiting sessions measured 0.8–2.5 GB on
    /// 2026-11-19, which 1 GB would have lit all the time (Decision 1).
    static let islandMemoryThreshold = 4 * bytesPerGB
    /// Binary units, as Activity Monitor's Memory column counts them.
    static let bytesPerMB = 1_048_576
    static let bytesPerGB = 1_073_741_824

    /// The figure on `scale`, from the per-core one: as it is, or over the active cores and
    /// never above 100 (a count below one reads as one). Negative or not finite reads as 0.
    static func cpuValue(perCore: Double, scale: AgentCPUScale, cores: Int) -> Double {
        guard perCore.isFinite, perCore > 0 else { return 0 }
        switch scale {
        case .perCore: return perCore
        case .wholeMac: return min(100, perCore / Double(max(1, cores)))
        }
    }

    /// "212%": a whole percent, spelled as `PercentDisplay` spells every other percent in the
    /// island, with no space.
    static func cpuText(perCore: Double, scale: AgentCPUScale, cores: Int) -> String {
        let value = cpuValue(perCore: perCore, scale: scale, cores: cores)
        return "\(Int(min(value, 1_000_000).rounded()))%"
    }

    /// "634 MB" below a gigabyte, "3.4 GB" from it; a count that rounds to 1024 MB is "1.0 GB".
    static func memoryText(bytes: Int) -> String {
        let megabytes = (Double(max(0, bytes)) / Double(bytesPerMB)).rounded()
        guard megabytes >= 1024 else { return "\(Int(megabytes)) MB" }
        return String(format: "%.1f GB", Double(bytes) / Double(bytesPerGB))
    }

    /// The island's suffix, "212% · 3.4 GB": only from 50 % CPU per core or 4 GB up, so idle
    /// sessions stay quiet (Decision 1); memory alone before the second reading.
    static func islandSuffix(_ figures: AgentResourceRules.Figures?, scale: AgentCPUScale, cores: Int) -> String? {
        guard let figures else { return nil }
        let busy = (figures.cpuPercent ?? 0) >= islandCPUThreshold
        let large = figures.memoryBytes >= islandMemoryThreshold
        guard busy || large else { return nil }
        return line(figures, scale: scale, cores: cores, cpuWord: "")
    }

    /// The Agents tab's figures for every measured session, "212% CPU · 3.4 GB"; memory alone
    /// before the second reading; nil for a session without figures.
    static func dashboardText(_ figures: AgentResourceRules.Figures?, scale: AgentCPUScale, cores: Int) -> String? {
        guard let figures else { return nil }
        return line(figures, scale: scale, cores: cores, cpuWord: " CPU")
    }

    private static func line(
        _ figures: AgentResourceRules.Figures, scale: AgentCPUScale, cores: Int, cpuWord: String
    ) -> String {
        let memory = memoryText(bytes: figures.memoryBytes)
        guard let cpu = figures.cpuPercent else { return memory }
        return "\(cpuText(perCore: cpu, scale: scale, cores: cores))\(cpuWord) · \(memory)"
    }
}
