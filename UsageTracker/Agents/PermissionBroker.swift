import AppKit
import Combine

/// One Claude Code permission request Omelette is holding. Carries only what the
/// notification and the popover row show (spec rule 6): the tool name and the
/// ≤ 80-char summary — never the tool input.
struct PendingPermission: Identifiable, Equatable, Sendable {
    let id: String                 // request_id
    let sessionID: String          // AgentSession.id ("claude:<uuid>")
    let toolName: String?
    let toolSummary: String?
    /// The full text behind the summary, for the banner's second line and the row's
    /// expanded block. Still nothing but what the summary rules extracted — the tool
    /// input itself never leaves the decoder (spec rule 6).
    let detail: String?
    /// Set when the request *is* a question or a plan (`AskUserQuestion`,
    /// `ExitPlanMode` can themselves need permission). Allow then means "go ahead and
    /// ask me in the terminal", which the banner has to say in so many words.
    let attention: AgentAttention?
    let receivedAt: Date
    let expiresAt: Date
}

/// Why a hold ended. Passed to `PermissionBroker.onResolved` once the request has
/// left `pending`.
enum PermissionResolution: Equatable, Sendable {
    case answered(PermissionDecision)   // Allow / Deny from the notification or the row
    case releasedForPresence            // the hosting app became frontmost (or already was)
    case expired                        // the 120 s hold ran out, or the helper went away first
}

/// Decides what happens to a `PermissionRequest` the server is holding: release it at
/// once (the user is looking at that terminal, the feature is off, or we don't know
/// where the session lives) or hold it for up to `holdWindow` while the UI offers
/// Allow / Deny. Everything lives in memory (spec rule 4); only `answer(id:_:)` can
/// ever produce an `allow` (rule 7); every id is consumed on first resolution (rule 3).
@MainActor
final class PermissionBroker: ObservableObject {
    static let shared = PermissionBroker()

    /// Spec: hold up to 120 s. The helper waits 140 s and the hook allows 150 s, so
    /// the app always gives up first and withdraws its UI before the helper can.
    static let holdWindow: TimeInterval = 120

    /// Newest first.
    @Published private(set) var pending: [PendingPermission] = []

    /// Diagnostics (Settings → Agents, package 2).
    private(set) var answeredCount = 0
    private(set) var expiredCount = 0
    private(set) var releasedForPresenceCount = 0

    /// A request was just held — package 2 files the Allow / Deny notification.
    var onPending: ((PendingPermission) -> Void)?
    /// A request is gone from `pending` (and the session's `pendingPermissionID` is
    /// cleared) — package 2 withdraws the notification and, on `.expired`, falls back
    /// to the plain needs-you banner.
    var onResolved: ((PendingPermission, PermissionResolution) -> Void)?

    private struct Held {
        let reply: AgentReply
        let host: AgentHostInfo
        var expiry: Task<Void, Never>?
    }
    private var held: [String: Held] = [:]
    private var presenceRecheck: Task<Void, Never>?
    private let store: AgentSessionStore
    private let presence: PresenceMonitor
    private let featureEnabled: @MainActor () -> Bool
    private let holdWindow: TimeInterval
    private let recheckInterval: TimeInterval

    /// `featureEnabled` is `@MainActor` so the default (a static of this class) and
    /// test closures reading main-actor state pass without losing the actor; it is
    /// only ever called from `register`.
    init(
        store: AgentSessionStore = .shared,
        presence: PresenceMonitor = .shared,
        featureEnabled: @escaping @MainActor () -> Bool = PermissionBroker.featureIsUsable,
        holdWindow: TimeInterval = PermissionBroker.holdWindow,
        recheckInterval: TimeInterval = 1
    ) {
        self.store = store
        self.presence = presence
        self.featureEnabled = featureEnabled
        self.holdWindow = holdWindow
        self.recheckInterval = recheckInterval
        presence.onActivation = { [weak self] front in
            self?.hostActivated(front)
        }
    }

    /// The production feature flag: the switch is on *and* at least one agent's
    /// hooks are exactly this build's template. A hold only makes sense if the
    /// `PermissionRequest` hook is registered with the 150 s cap; an install from 2.1
    /// (`timeout: 5`, which reads `.outdated`) has the agent kill the helper after
    /// five seconds, and a five-second Allow/Deny banner that vanishes on its own is
    /// worse than the terminal prompt. Four small file reads per request — the same
    /// checks Settings → Agents polls every 2 s.
    static func featureIsUsable() -> Bool {
        featureIsUsable(
            settingEnabled: SettingsStore.shared.agentsAnswerPermissions,
            claudeHooks: AgentHooksInstaller.claudeStatus(
                settingsURL: AgentPaths.claudeSettingsURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            ),
            codexHooks: AgentHooksInstaller.codexHooksStatus(
                hooksURL: AgentPaths.codexHooksURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            ),
            codexTrust: AgentHooksInstaller.codexTrust(
                configURL: AgentPaths.codexConfigURL,
                hooksURL: AgentPaths.codexHooksURL
            )
        )
    }

    /// The truth table, as a pure function. One usable source is enough — the broker
    /// holds whatever arrives with a request id, whoever sent it. Codex needs the
    /// second half: a hook it has not been told to trust is one it refuses to run,
    /// and Allow / Deny for a question nobody asked is the worst of both worlds.
    ///
    /// `nonisolated` because it reads nothing but its arguments: the Agents tab's
    /// caption asks the same question from outside the main actor.
    nonisolated static func featureIsUsable(
        settingEnabled: Bool,
        claudeHooks: HookInstallStatus,
        codexHooks: HookInstallStatus,
        codexTrust: AgentHooksInstaller.CodexTrustStatus
    ) -> Bool {
        guard settingEnabled else { return false }
        return claudeHooks == .installed || (codexHooks == .installed && codexTrust == .trusted)
    }

    /// The whole policy, as a pure function (spec).
    static func shouldHold(userAtHost: Bool, featureEnabled: Bool, hasHost: Bool) -> Bool {
        featureEnabled && hasHost && !userAtHost
    }

    /// Called by the channel for every `permissionRequested` event, *before* the store
    /// applies it (so `pending(for:)` already answers inside `onNeedsYou`).
    func register(event: AgentEvent, reply: AgentReply, session: AgentSession?, now: Date = Date()) {
        guard event.kind == .permissionRequested, let id = reply.requestID else {
            reply.send(nil)   // nothing to hold (v1 helper, or a misrouted event)
            return
        }
        // Ids are 128 random bits, so a repeat is a replay or a bug, never a second
        // question: overwriting the entry would leave a phantom row in `pending`.
        guard held[id] == nil else {
            reply.send(nil)
            return
        }
        let host = event.host == .none ? (session?.host ?? .none) : event.host
        let hasHost = host.pid != nil || host.bundleID != nil
        let userAtHost = hasHost && presence.isUserAt(host: host)
        guard Self.shouldHold(userAtHost: userAtHost, featureEnabled: featureEnabled(), hasHost: hasHost) else {
            if userAtHost { releasedForPresenceCount += 1 }
            reply.send(nil)
            return
        }

        let sessionID = session?.id ?? AgentSession.makeID(source: event.source, sessionID: event.sessionID)
        // Claude Code blocks on the hook, so a second request for the same session
        // means the first hook is already gone (killed by an old 5 s timeout).
        for stale in pending where stale.sessionID == sessionID {
            resolve(id: stale.id, decision: nil, as: .expired)
        }

        let request = PendingPermission(
            id: id, sessionID: sessionID, toolName: event.toolName, toolSummary: event.toolSummary,
            detail: event.toolDetail, attention: event.attention,
            receivedAt: now, expiresAt: now.addingTimeInterval(holdWindow)
        )
        held[id] = Held(reply: reply, host: host, expiry: nil)
        pending.insert(request, at: 0)
        store.setPendingPermission(id: id, for: sessionID)
        reply.onPeerClosed { [weak self] in
            Task { @MainActor [weak self] in self?.peerLeft(id: id) }
        }
        held[id]?.expiry = Task { [weak self, holdWindow] in
            try? await Task.sleep(nanoseconds: UInt64(holdWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expire(id: id)
        }
        NSLog("[UT] permission held request=%@ session=%@", String(id.prefix(8)), String(event.sessionID.prefix(8)))
        startPresenceRecheckIfNeeded()
        onPending?(request)
    }

    /// Activation is the fast path; this is the slow one. Un-minimising a window,
    /// un-hiding the app with ⌘H or switching Spaces changes nothing NSWorkspace
    /// announces, so while anything is held the presence rule is asked again once
    /// a second and a hold whose terminal became visible goes back to it.
    private func startPresenceRecheckIfNeeded() {
        guard presenceRecheck == nil else { return }
        presenceRecheck = Task { [weak self, recheckInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(recheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.recheckPresence()
            }
        }
    }

    private func recheckPresence() {
        let ids = held.filter { presence.isUserAt(host: $0.value.host) }.map(\.key)
        for id in ids { release(id: id) }
    }

    /// User action. Idempotent: a second click, or a click after expiry, does nothing.
    func answer(id: String, _ decision: PermissionDecision) {
        guard held[id] != nil else { return }
        answeredCount += 1
        resolve(id: id, decision: decision, as: .answered(decision))
    }

    /// No decision — the user went back to the terminal. Idempotent.
    func release(id: String) {
        guard held[id] != nil else { return }
        releasedForPresenceCount += 1
        resolve(id: id, decision: nil, as: .releasedForPresence)
    }

    func releaseAll(for sessionID: String) {
        for id in pending.filter({ $0.sessionID == sessionID }).map(\.id) {
            release(id: id)
        }
    }

    func pending(for sessionID: String) -> PendingPermission? {
        pending.first { $0.sessionID == sessionID }
    }

    // MARK: - Private

    private func expire(id: String) {
        guard held[id] != nil else { return }
        expiredCount += 1
        resolve(id: id, decision: nil, as: .expired)
    }

    /// The helper hung up before anyone answered: same outcome as expiry for the user
    /// (Claude Code is showing its own prompt), so it is counted and reported as one.
    private func peerLeft(id: String) {
        expire(id: id)
    }

    /// An app came to the front (or the screen unlocked with one already there):
    /// every hold whose host that is goes back to the terminal.
    private func hostActivated(_ front: PresenceMonitor.Frontmost) {
        let ids = held.filter { PresenceMonitor.matches(frontmost: front, host: $0.value.host) }.map(\.key)
        for id in ids { release(id: id) }
    }

    /// Consumes the id: sends (at most once — `AgentReply` is idempotent too), cancels
    /// the expiry, drops the row, clears the store field, and only then tells the UI.
    private func resolve(id: String, decision: PermissionDecision?, as resolution: PermissionResolution) {
        guard let entry = held.removeValue(forKey: id),
              let index = pending.firstIndex(where: { $0.id == id }) else { return }
        entry.expiry?.cancel()
        entry.reply.send(decision)
        let request = pending.remove(at: index)
        store.setPendingPermission(id: nil, for: request.sessionID)
        if held.isEmpty {
            presenceRecheck?.cancel()
            presenceRecheck = nil
        }
        NSLog("[UT] permission resolved request=%@ %@", String(id.prefix(8)), String(describing: resolution))
        onResolved?(request, resolution)
    }
}
