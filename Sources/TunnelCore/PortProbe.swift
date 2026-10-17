import Foundation
import Darwin

public enum PortProbe {
    /// Returns true only when binding fails with EADDRINUSE. Other failures
    /// (bad address, privileged port) are left for the real tool to report.
    public static func isInUse(address: String, port: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &results) == 0, let first = results else {
            return false
        }
        defer { freeaddrinfo(results) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // ssh also sets SO_REUSEADDR, so match it to avoid TIME_WAIT false positives.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        if bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) != 0 {
            return errno == EADDRINUSE
        }
        return false
    }
}
