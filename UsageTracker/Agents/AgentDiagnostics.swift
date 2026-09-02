import Foundation

/// Read side for Settings → Agents (package 3): the live server's counters.
/// Main-actor isolated so the static is concurrency-safe under Swift 6.
@MainActor
enum AgentDiagnostics {
    /// Set by `AgentChannel` after a successful `start()`; nil when the socket
    /// could not be bound or the channel was stopped.
    static weak var server: AgentEventServer?
}
