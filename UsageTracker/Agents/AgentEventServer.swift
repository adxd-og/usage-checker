import Foundation

/// Listens on a Unix domain socket for one-line JSON messages from `omelette-hook`.
///
/// POSIX sockets rather than Network.framework: `NWListener` cannot set the socket
/// file's mode, does not unlink a stale file and leaves the file behind on cancel;
/// here the file is `chmod 0600` before `listen()`, so there is never a moment when
/// another local user could connect. One connection carries one message: read until
/// "\n" / EOF / 64 KB / 1 s, decode, answer with the one-line reply, close.
///
/// Threading: accept and reads run on `queue` (serial — hooks from one session are
/// handed over in accept order); `onEvent` and both counters run on the main queue.
/// The owner calls `stop()`; it is deliberately not called from `deinit`.
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
    /// Sent after every message; the helper reads it only for PermissionRequest and
    /// ignores its content in phase 2 (phase 4 will carry a decision here).
    static let reply = Data("{\"v\":1,\"decision\":null}\n".utf8)

    let socketURL: URL
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let queue = DispatchQueue(label: "com.usagetracker.agent-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Diagnostics (Settings → Agents, package 3). Main queue only.
    private(set) var receivedCount = 0
    private(set) var droppedCount = 0

    init(socketURL: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.socketURL = socketURL
        self.onEvent = onEvent
    }

    /// Unlinks a stale socket file, binds, chmod 0600, listens. Synchronous: clients
    /// can connect as soon as this returns.
    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    func stop() {
        queue.sync {
            guard let source = acceptSource else { return }
            source.cancel()           // the cancel handler closes the fd
            acceptSource = nil
            listenFD = -1
            unlink(socketURL.path)
        }
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

    /// Drains every queued connection (the listening fd is non-blocking).
    private func acceptPending() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nothing more queued
            // SO_NOSIGPIPE comes from the listening socket by inheritance (see start).
            serve(client)
            close(client)
        }
    }

    // MARK: - One connection

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
                return
            }
            newline = buffer.firstIndex(of: 0x0A)
        }

        let message = newline.map { buffer.subdata(in: buffer.startIndex..<$0) } ?? buffer
        guard !message.isEmpty else {
            drop(reason: "empty")
            return
        }
        do {
            let event = try AgentEventDecoder.decode(message)
            DispatchQueue.main.async { [self] in
                receivedCount += 1
                onEvent(event)
            }
        } catch {
            // Error cases name a field at most — never the payload.
            drop(reason: String(describing: error))
        }
        _ = Self.reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func drop(reason: String) {
        NSLog("[UT] agent event dropped: %@", reason)
        DispatchQueue.main.async { [self] in droppedCount += 1 }
    }

    /// Blocks the socket queue until `fd` is ready for `events` or `deadline` passes.
    private static func wait(_ fd: Int32, for events: Int32, until deadline: Date) -> Bool {
        let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        return poll(&descriptor, 1, remainingMilliseconds) > 0
    }
}
