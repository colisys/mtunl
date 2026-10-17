import Foundation
import Darwin

enum UnixSocket {
    static let maximumFrameBytes = 256 * 1024

    static func address(for path: String) -> (sockaddr_un, socklen_t)? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = path.utf8.count
        guard length > 0, length < MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
            return nil
        }
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                bytes.copyBytes(from: UnsafeRawBufferPointer(start: source, count: length))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + length + 1)
        address.sun_len = UInt8(size)
        return (address, size)
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads up to the first newline. Returns nil on EOF, error, timeout or oversize.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maximumFrameBytes {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                guard data.count + newline <= maximumFrameBytes else { return nil }
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        return nil
    }

    static func writeLine(_ fd: Int32, _ payload: Data) -> Bool {
        var data = payload
        data.append(10)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

public enum ControlClientError: LocalizedError {
    case notRunning
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notRunning: return "mtunl 守护进程未运行"
        case .failed(let message): return message
        }
    }
}

public struct ControlClient: Sendable {
    public let path: String
    public init(path: String = ControlPaths.socket) { self.path = path }

    public func send(_ request: ControlRequest, timeout: Int = 10) throws -> ControlResponse {
        guard getuid() != 0, geteuid() != 0 else { throw ControlClientError.failed("User client cannot run as root") }
        guard let (address, size) = UnixSocket.address(for: path) else {
            throw ControlClientError.failed("控制 socket 路径无效")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.failed("无法创建 socket") }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: timeout)
        var copy = address
        let connected = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { throw ControlClientError.notRunning }
        var peer: uid_t = 0; var group: gid_t = 0
        guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else {
            throw ControlClientError.failed("Unexpected daemon UID")
        }
        guard UnixSocket.writeLine(fd, try JSONEncoder().encode(request)) else {
            throw ControlClientError.failed("发送请求失败")
        }
        guard let line = UnixSocket.readLine(fd) else {
            throw ControlClientError.failed("守护进程响应不完整或超时")
        }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }

    public func isRunning() -> Bool {
        (try? send(ControlRequest(command: "ping"), timeout: 2).success) ?? false
    }
}
