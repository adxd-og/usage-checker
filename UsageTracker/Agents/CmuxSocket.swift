import Foundation

/// Connect → write the lines → close. Everything about this is best effort: cmux not
/// running is the normal case for almost everyone, and a jump that half worked (the
/// app is in front, the tab is not) is still most of the value. Nothing here throws
/// and nothing reaches the UI.
///
/// Same POSIX shape as the helper's `SocketClient`, deliberately duplicated: that file
/// lives in the `OmeletteHook` target, which shares no sources with the app, and this
/// one never waits for a reply.
enum CmuxSocket {
    /// cmux's own default when `CMUX_SOCKET_PATH` is not exported.
    static let defaultPath = "/tmp/cmux.sock"
    /// Connect + write budget. This runs on the main actor from a popover click, so it
    /// is short enough that a wedged socket is not a hang.
    static let timeout: TimeInterval = 0.5

    @discardableResult
    static func send(lines: [String], to path: String, timeout: TimeInterval = CmuxSocket.timeout) -> Bool {
        guard !lines.isEmpty else { return false }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)   // 104, including the NUL
        guard path.utf8.count < capacity else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
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

        let deadline = Date().addingTimeInterval(timeout)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            // Unix sockets connect synchronously unless the backlog is full (EINPROGRESS).
            guard errno == EINPROGRESS, wait(fd, for: POLLOUT, until: deadline) else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return false }
        }

        return writeAll(fd, Data(lines.map { $0 + "\n" }.joined().utf8), until: deadline)
    }

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
        while true {
            let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, remainingMilliseconds)
            if ready < 0, errno == EINTR { continue }
            return ready > 0
        }
    }
}
