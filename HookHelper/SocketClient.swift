import Foundation

/// Connect → write one line → optionally wait for one reply line → close. Every
/// failure is silent: Omelette not running is the normal case, not an error.
enum SocketClient {
    static func send(_ line: Data, to path: String, connectTimeout: TimeInterval, replyTimeout: TimeInterval) {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)   // 104, including the NUL
        guard path.utf8.count < capacity else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
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

        let deadline = Date().addingTimeInterval(connectTimeout)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            // Unix sockets connect synchronously unless the backlog is full (EINPROGRESS).
            guard errno == EINPROGRESS, wait(fd, for: POLLOUT, until: deadline) else { return }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return }
        }

        guard writeAll(fd, line, until: deadline) else { return }
        guard replyTimeout > 0, wait(fd, for: POLLIN, until: Date().addingTimeInterval(replyTimeout)) else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buffer, buffer.count)   // phase 2 ignores the reply; phase 4 reads a decision here
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
