import Foundation
import Darwin

public enum ControlServerError: LocalizedError {
    case alreadyRunning
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "mtunl 守护进程已在运行"
        case .failed(let message): return message
        }
    }
}

/// Newline-delimited JSON over a user-only Unix socket.
public final class ControlServer: @unchecked Sendable {
    private let handler: ControlHandler
    private let directory: String
    private let path: String
    private var listenFD: Int32 = -1
    private var lease: SocketLease?
    private let lock = NSLock()
    private var stopped = false
    private let clients = DispatchQueue(label: "mtunl.control.clients", attributes: .concurrent)

    public init(handler: ControlHandler, path: String = ControlPaths.socket) {
        self.handler = handler
        self.path = path
        self.directory = (path as NSString).deletingLastPathComponent
    }

    public func start() throws {
        guard getuid() != 0, geteuid() != 0 else { throw ControlServerError.failed("User server cannot run as root") }
        try prepareDirectory()
        let acquired = try SocketLease(path: directory + "/daemon.lock", owner: getuid())
        if ControlClient(path: path).isRunning() { throw ControlServerError.alreadyRunning }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                throw ControlServerError.failed("Unsafe control socket")
            }
            unlink(path)
        }

        guard let (address, size) = UnixSocket.address(for: path) else {
            throw ControlServerError.failed("控制 socket 路径无效")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.failed("无法创建 socket") }
        var copy = address
        let bound = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ControlServerError.failed("无法监听 \(path)：\(reason)")
        }
        lease = acquired
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        if listenFD >= 0 { close(listenFD); unlink(path) }
        lease = nil
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// The directory must be ours, private, and not a symlink: /tmp is shared.
    private func prepareDirectory() throws {
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard mkdir(directory, 0o700) == 0 else {
                throw ControlServerError.failed("无法创建 \(directory)：\(String(cString: strerror(errno)))")
            }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw ControlServerError.failed("\(directory) 不是当前用户的目录，拒绝使用")
        }
        if info.st_mode & 0o077 != 0 { chmod(directory, 0o700) }
    }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 500)
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            clients.async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: 5)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        guard let line = UnixSocket.readLine(fd) else { return }
        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            response = handler.handle(request)
        } else {
            response = ControlResponse(success: false, error: "请求格式无效")
        }
        if let data = try? JSONEncoder().encode(response) { _ = UnixSocket.writeLine(fd, data) }
    }
}
