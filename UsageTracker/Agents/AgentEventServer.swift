import Foundation

/// Listens on a Unix domain socket for one-line JSON messages from `omelette-hook`.
///
/// POSIX sockets rather than Network.framework: `NWListener` cannot set the socket
/// file's mode, does not unlink a stale file and leaves the file behind on cancel;
/// here the file is `chmod 0600` before `listen()`, so there is never a moment when
/// another local user could connect. One connection carries one message: read until
/// "\n" / EOF / 64 KB / 1 s, decode, answer, close.
///
/// Phase 4: every accepted peer is authenticated with `LOCAL_PEERCRED` (same uid or
/// closed unanswered), and each connection is served on its own serial queue. A
/// `PermissionRequest` that carries a request id is *held*: `onEvent` receives an
/// unsettled `AgentReply`, and the connection's queue parks in `poll` until the reply
/// is sent, the helper leaves, or `holdTimeout` passes — nothing else waits on it.
/// Every other event is answered with `reply` on the spot, before `onEvent` runs.
///
/// Threading: accept runs on `queue` (serial); reads and holds on a per-connection
/// queue; `onEvent` and the counters on the main queue. The owner calls `stop()`; it
/// is deliberately not called from `deinit`.
final class AgentEventServer: @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case pathTooLong(Int)
        case alreadyStarted
        case posix(call: String, errno: Int32)
    }

    /// Spec cap per message. Anything longer is dropped without decoding.
    static let maxMessageBytes = 64 * 1024
    /// Read budget per connection. The helper writes immediately after connecting;
    /// a client that stalls longer than this is counted as dropped.
    static let connectionTimeout: TimeInterval = 1.0
    /// How long a held `PermissionRequest` connection may wait for `AgentReply.send`.
    /// The helper gives up at the same 140 s; the broker's 120 s window sits inside
    /// both (spec rule 5), so in practice this only fires if the broker is bypassed.
    static let defaultHoldTimeout: TimeInterval = 140
    /// Sent immediately for every event that is not held; the helper reads it only
    /// for a `PermissionRequest` it did not tag with a request id (a v1 helper).
    static let reply = Data("{\"v\":1,\"decision\":null}\n".utf8)

    /// Effective uid of the process on the other end of an accepted Unix socket, or
    /// nil when the kernel will not say (not a socket, unsupported family).
    static let localPeerUID: @Sendable (Int32) -> uid_t? = { fd in
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        return credentials.cr_uid
    }

    let socketURL: URL
    let holdTimeout: TimeInterval
    private let peerUID: @Sendable (Int32) -> uid_t?
    private let onEvent: @Sendable (AgentEvent, AgentReply) -> Void
    private let queue = DispatchQueue(label: "com.usagetracker.agent-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Identity of the file this instance bound. A second Omelette instance takes the
    /// path over (see `startOnQueue`); when this one then quits, the file at the path
    /// is no longer ours and must survive our `stop()`.
    private var boundIdentity: FileIdentity?

    /// Diagnostics (Settings → Agents). Main queue only. `rejectedPeerCount` is the
    /// subset of `droppedCount` that failed the uid check.
    private(set) var receivedCount = 0
    private(set) var droppedCount = 0
    private(set) var rejectedPeerCount = 0

    /// `peerUID` exists so tests can simulate a foreign peer; production uses `localPeerUID`.
    init(
        socketURL: URL,
        holdTimeout: TimeInterval = AgentEventServer.defaultHoldTimeout,
        peerUID: @escaping @Sendable (Int32) -> uid_t? = AgentEventServer.localPeerUID,
        onEvent: @escaping @Sendable (AgentEvent, AgentReply) -> Void
    ) {
        self.socketURL = socketURL
        self.holdTimeout = holdTimeout
        self.peerUID = peerUID
        self.onEvent = onEvent
    }

    /// Unlinks a stale socket file, binds, chmod 0600, listens. Synchronous: clients
    /// can connect as soon as this returns.
    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    /// Idempotent. Removes the socket file only when it is still the one we bound.
    func stop() {
        queue.sync {
            guard let source = acceptSource else { return }
            source.cancel()           // the cancel handler closes the fd
            acceptSource = nil
            listenFD = -1
            let ours = boundIdentity
            boundIdentity = nil
            guard let ours, Self.identity(ofFileAt: socketURL.path) == ours else { return }
            unlink(socketURL.path)
        }
    }

    // MARK: - Socket file identity

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func identity(ofFileAt path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    // MARK: - Listening

    private func startOnQueue() throws {
        guard acceptSource == nil else { throw Error.alreadyStarted }
        let path = socketURL.path
        guard path.utf8.count <= AgentPaths.maxSocketPathBytes else { throw Error.pathTooLong(path.utf8.count) }
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A crash leaves the file behind, and a second Omelette instance (login copy +
        // dev build) takes the path over: the last launched instance wins.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.posix(call: "socket", errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        // SO_NOSIGPIPE must be set here, on the listening socket: accepted sockets
        // inherit it, and setting it on an accepted socket whose peer has already
        // closed fails with EINVAL (measured) — which is exactly the fire-and-forget
        // helper's case (write, close, we accept afterwards). Without the flag our
        // reply write to that dead peer raises a process-wide SIGPIPE and kills the app.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = Self.address(for: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Error.posix(call: "bind", errno: code)
        }
        // bind() created the file; remember which file it is so stop() can tell it apart
        // from one a later instance bound to the same path.
        let identity = Self.identity(ofFileAt: path)
        // Before listen(): nobody can connect yet, so the mode is 0600 from the first
        // moment a connection is possible.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Error.posix(call: "chmod", errno: code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Error.posix(call: "listen", errno: code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenFD = fd
        acceptSource = source
        boundIdentity = identity
    }

    private static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        return address
    }

    /// Drains every queued connection (the listening fd is non-blocking). Each one is
    /// authenticated here and then handed to its own queue, so a held request never
    /// stands between the next hook and its reply.
    private func acceptPending() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nothing more queued
            // SO_NOSIGPIPE and O_NONBLOCK come from the listening socket by inheritance.
            guard peerUID(client) == getuid() else {
                close(client)
                rejectPeer()
                continue
            }
            let connection = DispatchQueue(label: "com.usagetracker.agent-conn")
            connection.async { [self] in serve(client) }
        }
    }

    // MARK: - One connection

    /// Runs on the connection's own queue; owns `fd` until it returns.
    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(Self.connectionTimeout)
        var newline: Data.Index?
        while newline == nil {
            guard Self.wait(fd, for: POLLIN, until: deadline) else { break }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }                    // EOF or error: what arrived is the message
            buffer.append(chunk, count: count)
            if buffer.count > Self.maxMessageBytes {
                drop(reason: "over \(Self.maxMessageBytes / 1024) KB")
                close(fd)
                return
            }
            newline = buffer.firstIndex(of: 0x0A)
        }

        let message = newline.map { buffer.subdata(in: buffer.startIndex..<$0) } ?? buffer
        guard !message.isEmpty else {
            drop(reason: "empty")
            close(fd)
            return
        }
        do {
            let event = try AgentEventDecoder.decode(message)
            if event.kind == .permissionRequested, let requestID = event.requestID {
                hold(fd, event: event, requestID: requestID)
                return
            }
            DispatchQueue.main.async { [self] in
                receivedCount += 1
                onEvent(event, AgentReply(requestID: nil))
            }
        } catch {
            // Error cases name a field at most — never the payload.
            drop(reason: String(describing: error))
        }
        _ = Self.reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// Parks this connection's queue — only this one — until the app answers, the
    /// helper goes away, or the hold budget runs out. `AgentReply.send` shuts the
    /// socket down, which is what wakes the poll; the descriptor is released here and
    /// nowhere else.
    private func hold(_ fd: Int32, event: AgentEvent, requestID: String) {
        let reply = AgentReply(requestID: requestID, fd: fd)
        DispatchQueue.main.async { [self] in
            receivedCount += 1
            onEvent(event, reply)
        }
        if Self.wait(fd, for: POLLIN, until: Date().addingTimeInterval(holdTimeout)) {
            var byte: UInt8 = 0
            _ = read(fd, &byte, 1)
            reply.peerClosed()   // no-op when the wake-up was our own send()
        } else {
            reply.send(nil)      // budget exhausted: let the helper go without a decision
        }
        reply.closeDescriptor()
    }

    private func rejectPeer() {
        NSLog("[UT] agent connection rejected: peer uid is not ours")
        DispatchQueue.main.async { [self] in
            droppedCount += 1
            rejectedPeerCount += 1
        }
    }

    private func drop(reason: String) {
        NSLog("[UT] agent event dropped: %@", reason)
        DispatchQueue.main.async { [self] in droppedCount += 1 }
    }

    /// Blocks the socket queue until `fd` is ready for `events` or `deadline` passes.
    private static func wait(_ fd: Int32, for events: Int32, until deadline: Date) -> Bool {
        while true {
            let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, remainingMilliseconds)
            // A signal interrupting a 140 s hold must not read as "budget exhausted":
            // that would release the helper while the broker still shows the buttons.
            if ready < 0, errno == EINTR { continue }
            return ready > 0
        }
    }
}
