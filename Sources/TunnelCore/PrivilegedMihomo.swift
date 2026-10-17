import Foundation
import Darwin
import CryptoKit
import MihomoWatchdog

/// A pipe lease survives only in the helper; EOF also covers SIGKILL and crashes.
final class WatchedMihomoProcess {
    let processIdentifier: pid_t
    private let watchdog: pid_t
    private var lease: Int32
    private var exitStatus: Int32?
    init(binary: URL, directory: URL, config: URL, output: Int32) throws {
        var fd: Int32 = -1
        var pid: pid_t = -1
        let monitor = mtunl_watchdog_start(binary.path, directory.path, config.path, output, &fd, &pid)
        guard monitor > 0 else { throw MihomoError.process("Cannot start Mihomo watchdog") }
        watchdog = monitor; lease = fd; processIdentifier = pid
    }
    var isRunning: Bool {
        if exitStatus != nil { return false }
        var status: Int32 = 0
        let result = mtunl_watchdog_wait(watchdog, &status, 1)
        if result == 0 { return true }
        exitStatus = result < 0 ? 125 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        return false
    }
    var terminationStatus: Int32 { exitStatus ?? 0 }
    func terminate() {
        if lease >= 0 { close(lease); lease = -1 }
    }
    deinit {
        terminate()
        if exitStatus == nil {
            let pid = watchdog
            DispatchQueue.global().async { var status: Int32 = 0; _ = mtunl_watchdog_wait(pid, &status, 0) }
        }
    }
}

struct HelperConfiguration: Codable {
    var cidrs: [String]
    var mixedPort: Int
    var controllerPort: Int
    var socksPort: Int
    var autoRoute: Bool

    func yaml() throws -> String {
        guard cidrs.count <= 256, (1024...65535).contains(socksPort),
              socksPort != mixedPort, socksPort != controllerPort else {
            throw MihomoError.invalid("Invalid helper ports or CIDR count")
        }
        let tunnel = TunnelConfig(name: "helper", kind: .dynamic, host: "localhost", user: "unused", bindAddress: "127.0.0.1", listenPort: socksPort)
        let settings = MihomoSettings(dynamicTunnelID: tunnel.id, cidrs: cidrs, mixedPort: mixedPort, controllerPort: controllerPort, autoRoute: autoRoute)
        _ = try MihomoConfigBuilder.validate(settings, tunnels: [tunnel])
        return try MihomoConfigBuilder.yaml(settings: settings, socksPort: socksPort)
    }
}

struct HelperRequest: Codable {
    enum Operation: String, Codable { case start, stop, status, shutdown }
    var operation: Operation
    var configuration: HelperConfiguration? = nil
}

struct HelperResponse: Codable {
    var status: MihomoStatus
    var digest: String
    var error: String? = nil
    var controllerSecret: String? = nil
}

/// Kept open for the lifetime of the listener; never unlink a lock inode.
final class SocketLease {
    private let fd: Int32
    init(path: String, owner: uid_t) throws {
        fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        guard fd >= 0 else { throw MihomoError.process("Cannot open singleton lock") }
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else {
            close(fd); throw MihomoError.process("Unsafe singleton lock")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw ControlServerError.alreadyRunning
        }
    }
    deinit { close(fd) }
}

/// Serially called by the helper. Signals are sent only to the Process we own.
final class OwnedMihomo {
    private var child: WatchedMihomoProcess?
    private var output: Pipe?
    private let logLock = NSLock()
    private var lines: [String] = []
    private var status = MihomoStatus()
    private let binary: URL
    private let directory: URL
    let controllerSecret = UUID().uuidString + UUID().uuidString
    init(binary: URL, directory: URL) { self.binary = binary; self.directory = directory }
    func snapshot() -> MihomoStatus {
        if let child, !child.isRunning {
            status = MihomoStatus(state: .failed, message: "Mihomo exited: \(child.terminationStatus)")
            self.child = nil
        }
        logLock.lock(); status.log = lines; logLock.unlock()
        return status
    }
    func start(_ configuration: HelperConfiguration) throws -> MihomoStatus {
        let yaml = try configuration.yaml() + "\nsecret: \(controllerSecret)\n"
        if snapshot().state == .running { return status }
        let config = directory.appendingPathComponent("config.yaml")
        try Data(yaml.utf8).write(to: config, options: .atomic)
        chmod(config.path, 0o600)

        let pipe = Pipe()
        logLock.lock(); lines = []; logLock.unlock()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.logLock.lock()
            self.lines.append(contentsOf: String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { String($0.prefix(300)) })
            if self.lines.count > 30 { self.lines.removeFirst(self.lines.count - 30) }
            self.logLock.unlock()
        }
        let process: WatchedMihomoProcess
        do {
            process = try WatchedMihomoProcess(binary: binary, directory: directory, config: config,
                                               output: pipe.fileHandleForWriting.fileDescriptor)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        output = pipe
        child = process
        status = MihomoStatus(state: .running, pid: process.processIdentifier, configPath: config.path)
        return status
    }
    func stop() throws -> MihomoStatus {
        if let child, child.isRunning {
            child.terminate()
            let killDeadline = Date().addingTimeInterval(4)
            while child.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
            guard !child.isRunning else { throw MihomoError.process("Mihomo did not exit; ownership retained") }
        }
        child = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        status = MihomoStatus()
        return status
    }
}

protocol HelperTransport {
    func send(_ request: HelperRequest) throws -> HelperResponse
    func authorize(binary: URL, digest: String) throws
}

struct PrivilegedClient: HelperTransport {
    let uid: uid_t
    var directory: String { "/private/tmp/mtunl-helper-\(uid)" }
    var path: String { directory + "/helper.sock" }
    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    func send(_ request: HelperRequest) throws -> HelperResponse {
        guard getuid() != 0, geteuid() != 0 else { throw MihomoError.process("Helper client must run as user") }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0,
              lstat(path, &info) == 0, info.st_uid == uid,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600,
              let (address, size) = UnixSocket.address(for: path) else { throw ControlClientError.notRunning }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.notRunning }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: 6)
        var copy = address
        let result = withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        var peer: uid_t = 99; var group: gid_t = 0
        guard result == 0, getpeereid(fd, &peer, &group) == 0, peer == 0 else { throw ControlClientError.notRunning }
        guard UnixSocket.writeLine(fd, try JSONEncoder().encode(request)), let data = UnixSocket.readLine(fd) else {
            throw MihomoError.process("Helper response timed out")
        }
        let response = try JSONDecoder().decode(HelperResponse.self, from: data)
        if let error = response.error { throw MihomoError.process(error) }
        return response
    }
    static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func authorize(binary: URL, digest: String) throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("mtunl-helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MihomoError.process("Missing bundled mtunl-helper; rebuild/update daemon") }
        let command = "\(Self.quote(helper.path)) \(uid) \(getpid()) \(Self.quote(binary.path)) \(Self.quote(digest)) </dev/null >/dev/null 2>&1 &"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw MihomoError.process("Authorization timed out") }
        guard process.terminationStatus == 0 else { throw MihomoError.process("Authorization cancelled or failed") }
        for _ in 0..<50 {
            if (try? send(HelperRequest(operation: .status))) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MihomoError.process("Authorized helper failed to start")
    }
}

public enum PrivilegedHelper {
    public static func run(arguments: [String]) throws {
        guard getuid() == 0, geteuid() == 0, arguments.count == 4,
              let uid = uid_t(arguments[0]), uid > 0,
              let parent = Int32(arguments[1]), parent > 1,
              arguments[3].count == 64 else { throw MihomoError.process("Root helper requires UID, daemon PID, binary and SHA256") }
        var processInfo = kinfo_proc()
        var processInfoSize = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, parent]
        guard sysctl(&query, u_int(query.count), &processInfo, &processInfoSize, nil, 0) == 0,
              processInfoSize > 0, processInfo.kp_eproc.e_ucred.cr_uid == uid else {
            throw MihomoError.process("Daemon PID does not belong to authorized UID")
        }
        umask(0o077)
        let directory = "/private/tmp/mtunl-helper-\(uid)"
        if mkdir(directory, 0o755) == 0 { chmod(directory, 0o755) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else { throw MihomoError.process("Unsafe helper directory") }
        let lease = try SocketLease(path: directory + "/lock", owner: 0)
        // Pin bytes before executing anything. Later IPC cannot name executable/config paths.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == arguments[3] else { throw MihomoError.process("Authorized binary changed") }
        let session = URL(fileURLWithPath: directory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: session) }
        let binary = session.appendingPathComponent("mihomo")
        try bytes.write(to: binary, options: .atomic)
        chmod(binary.path, 0o700)
        let owner = OwnedMihomo(binary: binary, directory: session)
        defer { _ = try? owner.stop() }
        let path = directory + "/helper.sock"
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == uid else { throw MihomoError.process("Unsafe helper socket") }
            unlink(path)
        }
        guard let (address, size) = UnixSocket.address(for: path) else { throw MihomoError.process("Socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MihomoError.process("Cannot create helper socket") }
        defer { close(fd); unlink(path); withExtendedLifetime(lease) {} }
        var copy = address
        let bound = withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, chown(path, uid, gid_t.max) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw MihomoError.process("Cannot bind helper socket") }
        let events = kqueue()
        guard events >= 0 else { throw MihomoError.process("Cannot monitor daemon") }
        defer { close(events) }
        var event = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(events, &event, 1, nil, 0, nil) == 0 else { throw MihomoError.process("Daemon already exited") }
        var signals: [DispatchSourceSignal] = []
        let termination = DispatchSemaphore(value: 0)
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { termination.signal() }; source.resume(); signals.append(source)
        }
        defer { withExtendedLifetime(signals) {} }
        while termination.wait(timeout: .now()) != .success {
            var descriptors = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: events, events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, 2, 250)
            if descriptors[1].revents != 0 { break }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var shutdown = false
            do {
                defer { close(client) }
                UnixSocket.setTimeouts(client, seconds: 2)
                var peer: uid_t = 0; var group: gid_t = 0
                guard getpeereid(client, &peer, &group) == 0, peer == uid else { continue }
                var response = HelperResponse(status: owner.snapshot(), digest: digest, controllerSecret: owner.controllerSecret)
                do {
                    guard let data = UnixSocket.readLine(client) else { continue }
                    let request = try JSONDecoder().decode(HelperRequest.self, from: data)
                    switch request.operation {
                    case .status: break
                    case .start:
                        guard let config = request.configuration else { throw MihomoError.invalid("Missing typed configuration") }
                        response.status = try owner.start(config)
                    case .stop: response.status = try owner.stop()
                    case .shutdown: response.status = try owner.stop(); shutdown = true
                    }
                } catch { response.error = error.localizedDescription }
                _ = UnixSocket.writeLine(client, try JSONEncoder().encode(response))
            }
            if shutdown { break }
        }
    }
}
