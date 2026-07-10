import CodexBarCore
import Foundation

/// Spike: proves CodexBarCore (steipete/CodexBar, MIT) links into our app target.
/// Next step is an adapter mapping their provider snapshots onto our
/// ServiceSnapshot/UsageBucket model; until then this file just pins the import.
enum CodexBarCoreSpike {
    static let isLinked = true
}
