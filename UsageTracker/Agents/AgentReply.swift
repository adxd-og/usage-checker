import Foundation
import os

/// What the app may answer on a held `PermissionRequest`. Wire spelling.
enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

/// The answer side of one hook connection.
///
/// For a held `PermissionRequest` the server hands this to `onEvent` and then parks
/// the connection's queue in `poll` on the descriptor. `send` — from any thread, once —
/// writes the reply line and `shutdown`s the socket, which both delivers the line to
/// the helper and wakes that `poll`; the connection queue is the only thing that ever
/// `close`s the descriptor (`closeDescriptor`). A helper that exits first is seen by
/// the same `poll` and reported through `onPeerClosed`, so the broker can withdraw a
/// request nobody can answer any more.
///
/// For every other event the server has already written its immediate reply: the
/// handle is born settled and `send` is a no-op.
final class AgentReply: Sendable {
    let requestID: String?

    private struct State: Sendable {
        var fd: Int32                 // -1 once released (or never held)
        var settled: Bool             // a line went out, the peer left, or nothing was ever held
        var peerClosed = false
        var peerClosedHandler: (@Sendable () -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// `fd` is the accepted socket, owned by the server's connection queue. -1 builds
    /// an already-answered handle.
    init(requestID: String?, fd: Int32 = -1) {
        self.requestID = requestID
        state = OSAllocatedUnfairLock(initialState: State(fd: fd, settled: fd < 0))
    }

    var isSettled: Bool { state.withLock { $0.settled } }

    /// First call wins; later calls (a second click, expiry racing an answer) do nothing.
    func send(_ decision: PermissionDecision?) {
        sendRaw(Self.line(requestID: requestID, decision: decision))
    }

    /// Writes `line` verbatim if nothing has been sent yet. Tests use it to forge
    /// replies (wrong id, garbage) and prove the helper ignores them.
    func sendRaw(_ line: Data) {
        // The write and the shutdown stay under the lock: `closeDescriptor` on the
        // connection queue takes the same lock, so the number can never be closed —
        // and recycled for another hook — between reading it and using it. The fd
        // is non-blocking and the line is under 100 bytes, so nothing here waits.
        state.withLock { state in
            guard !state.settled else { return }
            state.settled = true
            guard state.fd >= 0 else { return }
            _ = line.withUnsafeBytes { write(state.fd, $0.baseAddress, $0.count) }
            // Delivers EOF after the line and wakes the connection queue's poll so it
            // releases the descriptor. EPIPE on a helper that already left is harmless:
            // SO_NOSIGPIPE is inherited from the listening socket.
            shutdown(state.fd, SHUT_RDWR)
        }
    }

    /// Runs `handler` once if the helper disconnects before any decision was sent —
    /// immediately, on the caller's thread, if it already has. Never runs after `send`.
    func onPeerClosed(_ handler: @escaping @Sendable () -> Void) {
        let fireNow: Bool = state.withLock { state in
            if state.peerClosed { return true }
            guard !state.settled else { return false }
            state.peerClosedHandler = handler
            return false
        }
        if fireNow { handler() }
    }

    /// Server side: the connection queue read EOF. A no-op after `send` (that EOF was
    /// our own shutdown).
    func peerClosed() {
        let handler: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.settled else { return nil }
            state.settled = true
            state.peerClosed = true
            defer { state.peerClosedHandler = nil }
            return state.peerClosedHandler
        }
        handler?()
    }

    /// Server side, connection queue only: releases the descriptor. Afterwards `send`
    /// cannot touch a number the kernel may have reused.
    func closeDescriptor() {
        let fd: Int32 = state.withLock { state in
            let fd = state.fd
            state.fd = -1
            state.settled = true
            return fd
        }
        if fd >= 0 { Darwin.close(fd) }
    }

    /// `{"v":2,"request_id":"<id>","decision":"allow"|"deny"|null}\n`. Built by hand:
    /// the id is validated hex and the decision a bare word, so nothing needs escaping
    /// and the key order is fixed for the tests.
    static func line(requestID: String?, decision: PermissionDecision?) -> Data {
        var text = "{\"v\":\(AgentPaths.wireVersion)"
        if let requestID { text += ",\"request_id\":\"\(requestID)\"" }
        text += ",\"decision\":" + (decision.map { "\"\($0.rawValue)\"" } ?? "null") + "}\n"
        return Data(text.utf8)
    }
}
