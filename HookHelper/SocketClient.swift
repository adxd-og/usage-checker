import Foundation

/// Connect → write one line → (PermissionRequest only) wait for the decision line.
/// Every failure is silent: Omelette not running is the normal case, not an error.
enum SocketClient {
    /// Connects within `connectTimeout`, writes `line`, and returns the connected
    /// descriptor so the caller can wait for a reply on it. nil (and the socket
    /// closed) when anything goes wrong. The caller closes a returned fd.
    static func send(_ line: Data, to path: String, connectTimeout: TimeInterval) -> Int32? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)   // 104, including the NUL
        guard path.utf8.count < capacity else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }

        let deadline = Date().addingTimeInterval(connectTimeout)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            // Unix sockets connect synchronously unless the backlog is full (EINPROGRESS).
            guard errno == EINPROGRESS, wait(fd, for: POLLOUT, until: deadline) else { close(fd); return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { close(fd); return nil }
        }

        guard writeAll(fd, line, until: deadline) else { close(fd); return nil }
        return fd
    }

    /// Reads one reply line and returns "allow" / "deny" only when it is a JSON object
    /// whose `request_id` is exactly ours and whose `decision` is one of those two
    /// words. Anything else — timeout, EOF (Omelette quit), garbage, a foreign id, a
    /// `null` or unknown decision — is nil. Fail closed (spec rule 1).
    static func awaitDecision(fd: Int32, requestID: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !buffer.contains(0x0A) {
            guard buffer.count < 4096, wait(fd, for: POLLIN, until: deadline) else { return nil }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { return nil }              // EOF: no decision survives Omelette going away
            buffer.append(chunk, count: count)
        }
        let line = buffer.prefix(while: { $0 != 0x0A })
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let id = object["request_id"] as? String, id == requestID,
              let decision = object["decision"] as? String, decision == "allow" || decision == "deny"
        else { return nil }
        return decision
    }

    /// The default AF_UNIX send buffer is 8 KB, so a 64 KB line takes several writes
    /// interleaved with the app's reads.
    private static func writeAll(_ fd: Int32, _ data: Data, until deadline: Date) -> Bool {
        var offset = 0
        while offset < data.count {
            guard wait(fd, for: POLLOUT, until: deadline) else { return false }
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + offset, data.count - offset)
            }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    private static func wait(_ fd: Int32, for events: Int32, until deadline: Date) -> Bool {
        let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        return poll(&descriptor, 1, remainingMilliseconds) > 0
    }
}
