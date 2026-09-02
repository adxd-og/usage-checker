import Foundation

/// Owns the hook → app channel for the app's lifetime: refreshes the helper
/// symlink, starts the socket server, fans events out to one consumer.
///
/// Package 2 replaces the log-only consumer by assigning `onEvent` in
/// `AppState.bootstrap()` — one line, nothing else moves. The server hands every
/// event over on the main queue, so the consumer always runs on the main actor.
@MainActor
final class AgentChannel {
    static let shared = AgentChannel()

    /// The single consumer. The default logs the event kind and a session-id prefix —
    /// never a payload, cwd or tool summary (spec, "Security and privacy") — and
    /// releases a held permission request, so a helper never waits on a consumer
    /// nobody installed.
    var onEvent: (AgentEvent, AgentReply) -> Void = { event, reply in
        NSLog("[UT] agent event %@ session=%@", String(describing: event.kind), String(event.sessionID.prefix(8)))
        reply.send(nil)
    }

    private(set) var server: AgentEventServer?
    /// Why the last `start()` failed, for Settings → Agents diagnostics.
    private(set) var startError: String?

    init() {}

    func start(
        socketURL: URL = AgentPaths.socketURL,
        refreshSymlink: Bool = true,
        historyURL: URL = AgentPaths.historyURL
    ) {
        if refreshSymlink {
            do {
                try AgentPaths.refreshHelperSymlink()
            } catch {
                // Hooks keep pointing at the old symlink target; Settings → Agents shows "outdated".
                NSLog("[UT] helper symlink refresh failed: %@", String(describing: error))
            }
        }
        guard server == nil else { return }

        // Once per launch, off the main actor: the run history is append-only, and
        // trimming it here is the only thing that keeps `agent-sessions.jsonl` from
        // growing forever. Detached because a long log must not delay the socket, and
        // below the guard so a second `start()` doesn't rotate a second time.
        Task.detached(priority: .utility) {
            do {
                try AgentHistoryStore(fileURL: historyURL).rotate()
            } catch {
                NSLog("[UT] agent history rotation failed: %@", String(describing: error))
            }
        }

        let server = AgentEventServer(socketURL: socketURL) { [weak self] event, reply in
            // AgentEventServer delivers on the main queue by contract (Task 5 of phase 2).
            MainActor.assumeIsolated {
                guard let self else { reply.send(nil); return }   // channel gone: release the helper
                self.onEvent(event, reply)
            }
        }
        do {
            try server.start()
            self.server = server
            startError = nil
            AgentDiagnostics.server = server
            NSLog("[UT] agent socket listening at %@", socketURL.path)
        } catch {
            startError = String(describing: error)
            NSLog("[UT] agent socket failed to start: %@", startError ?? "")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        AgentDiagnostics.server = nil
    }
}

/// What `AppState.bootstrap()` installs as `AgentChannel.shared.onEvent`. Kept as a
/// function over its two collaborators so the ordering rule is testable:
///
/// 1. A held `PermissionRequest` (it carries a request id) is registered with the
///    broker *first*, so that when the store applies the event and fires `onNeedsYou`
///    synchronously, `broker.pending(for:)` already answers and the notifier can
///    withhold the plain needs-you banner.
/// 2. Then the store applies it. For every other event only step 2 runs — the server
///    has already written the immediate reply.
enum AgentEventRouter {
    @MainActor
    static func handle(_ event: AgentEvent, reply: AgentReply, store: AgentSessionStore, broker: PermissionBroker) {
        if event.kind == .permissionRequested, reply.requestID != nil {
            let id = AgentSession.makeID(source: event.source, sessionID: event.sessionID)
            broker.register(event: event, reply: reply, session: store.sessions.first { $0.id == id })
        }
        store.apply(event)
    }
}
