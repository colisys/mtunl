import XCTest
import Darwin
@testable import TunnelCore

final class HelperTests: XCTestCase {
    private var config: HelperConfiguration {
        HelperConfiguration(cidrs: ["10.0.0.0/8"], mixedPort: 17890, controllerPort: 19090, socksPort: 1080, autoRoute: true)
    }
    private func fixture(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("fake")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: binary)
        chmod(binary.path, 0o700)
        return (directory, binary)
    }
    func testTypedProtocolRejectsCommandsAndInjection() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(HelperRequest.self, from: Data(#"{"operation":"exec","path":"/bin/sh"}"#.utf8)))
        for cidr in ["10.0.0.0/8\nexternal-controller: 0.0.0.0:80", "1.2.3.4/32,OTHER", "::/129"] {
            var invalid = config; invalid.cidrs = [cidr]
            XCTAssertThrowsError(try invalid.yaml())
        }
        var invalid = config; invalid.socksPort = 22
        XCTAssertThrowsError(try invalid.yaml())
        invalid = config; invalid.controllerPort = invalid.mixedPort
        XCTAssertThrowsError(try invalid.yaml())
        let request = HelperRequest(operation: .start, configuration: config)
        let data = try JSONEncoder().encode(request)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("binaryPath"))
        XCTAssertNoThrow(try JSONDecoder().decode(HelperRequest.self, from: data).configuration?.yaml())
    }
    func testSingletonAndSymlinkRejection() throws {
        let (directory, binary) = try fixture("exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lock").path
        var lease: SocketLease? = try SocketLease(path: path, owner: getuid())
        XCTAssertThrowsError(try SocketLease(path: path, owner: getuid()))
        withExtendedLifetime(lease) {}
        lease = nil
        XCTAssertNoThrow(try SocketLease(path: path, owner: getuid()))
        let link = directory.appendingPathComponent("link").path
        XCTAssertEqual(symlink(binary.path, link), 0)
        XCTAssertThrowsError(try SocketLease(path: link, owner: getuid()))
    }
    func testOwnedLifecycleIdempotenceAndForcedStop() throws {
        let (directory, binary) = try fixture("trap '' TERM\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OwnedMihomo(binary: binary, directory: directory)
        defer { _ = try? owner.stop() }
        let first = try owner.start(config)
        XCTAssertEqual(first.pid, try owner.start(config).pid)
        Thread.sleep(forTimeInterval: 0.1)
        let start = Date()
        XCTAssertEqual(try owner.stop().state, .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.5)
        XCTAssertEqual(kill(first.pid!, 0), -1)
        XCTAssertEqual(try owner.stop().state, .stopped)
        let yaml = try String(contentsOf: directory.appendingPathComponent("config.yaml"))
        XCTAssertTrue(yaml.contains("secret: " + owner.controllerSecret))
    }
    func testUnexpectedExitIsReported() throws {
        let (directory, binary) = try fixture("exit 7")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OwnedMihomo(binary: binary, directory: directory)
        _ = try owner.start(config)
        let deadline = Date().addingTimeInterval(2)
        while owner.snapshot().state == .running && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(owner.snapshot().state, .failed)
        XCTAssertTrue(owner.snapshot().message?.contains("7") == true)
    }
    func testHelperSIGKILLCleansKernel() throws {
        for ignoresTERM in [false, true] {
            let (directory, binary) = try fixture(ignoresTERM ? "trap '' TERM\nwhile :; do :; done" : "while :; do :; done")
            defer { try? FileManager.default.removeItem(at: directory) }
            // A separate C caller models the helper without forking the XCTest runtime.
            let source = directory.appendingPathComponent("caller.c")
            try Data("""
            #include "MihomoWatchdog.h"
            #include <stdio.h>
            #include <unistd.h>
            int main(int argc, char **argv) {
                int lease; pid_t kernel;
                if (mtunl_watchdog_start(argv[1], argv[2], argv[1], 2, &lease, &kernel) < 0) return 1;
                FILE *f = fopen(argv[3], "w");
                fprintf(f, "%d", kernel); fclose(f);
                for (;;) pause();
            }
            """.utf8).write(to: source)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let watchdog = root.appendingPathComponent("Sources/MihomoWatchdog")
            let executable = directory.appendingPathComponent("caller")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = ["-I", watchdog.appendingPathComponent("include").path, source.path,
                                  watchdog.appendingPathComponent("watchdog.c").path, "-o", executable.path]
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
            let pidFile = directory.appendingPathComponent("pid")
            let helper = Process()
            helper.executableURL = executable
            helper.arguments = [binary.path, directory.path, pidFile.path]
            try helper.run()
            defer { if helper.isRunning { kill(helper.processIdentifier, SIGKILL); helper.waitUntilExit() } }
            let readyDeadline = Date().addingTimeInterval(3)
            var kernel: Int32?
            while kernel == nil && Date() < readyDeadline {
                kernel = (try? String(contentsOf: pidFile)).flatMap(Int32.init)
                Thread.sleep(forTimeInterval: 0.02)
            }
            let pid = try XCTUnwrap(kernel)
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(kill(pid, 0), 0)
            XCTAssertEqual(kill(helper.processIdentifier, SIGKILL), 0)
            helper.waitUntilExit()
            let deadline = Date().addingTimeInterval(4)
            while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertEqual(kill(pid, 0), -1, "Kernel survived helper SIGKILL (ignores TERM: \(ignoresTERM))")
            XCTAssertEqual(errno, ESRCH)
        }
    }
    func testNonRootHelperRefusesStartup() throws {
        guard getuid() != 0 else { throw XCTSkip("Non-root test") }
        XCTAssertThrowsError(try PrivilegedHelper.run(arguments: ["501", "123", "/bin/sh", String(repeating: "0", count: 64)]))
        XCTAssertThrowsError(try PrivilegedClient(uid: getuid()).send(HelperRequest(operation: .status)))
    }
    func testFramingAndPeerCredentials() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { close($0) } }
        descriptors.forEach { UnixSocket.setTimeouts($0, seconds: 1) }
        var uid: uid_t = 0; var gid: gid_t = 0
        XCTAssertEqual(getpeereid(descriptors[0], &uid, &gid), 0)
        XCTAssertEqual(uid, getuid())
        let data = try JSONEncoder().encode(HelperRequest(operation: .status))
        XCTAssertTrue(UnixSocket.writeLine(descriptors[0], data))
        XCTAssertEqual(UnixSocket.readLine(descriptors[1]), data)
        XCTAssertNil(UnixSocket.address(for: String(repeating: "x", count: 200)))
    }
    func testAuthorizationDoesNotBlockStatusAndStopCancelsStart() throws {
        let (directory, binary) = try fixture("echo 'Mihomo Meta v9'")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DelayedAuthorization()
        let supervisor = MihomoSupervisor(kernelManager: MihomoKernelManager(root: directory), authorizeTUN: true,
                                           homeDirectory: directory, client: transport)
        let tunnel = TunnelConfig(name: "test", kind: .dynamic, host: "localhost", user: "test", listenPort: 1080)
        supervisor.apply(settings: MihomoSettings(binaryPath: binary.path, dynamicTunnelID: tunnel.id, cidrs: ["10.0.0.0/8"]), tunnels: [tunnel])
        supervisor.start()
        XCTAssertEqual(transport.entered.wait(timeout: .now() + 2), .success)
        let start = Date()
        XCTAssertEqual(supervisor.currentStatus().state, .starting)
        supervisor.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        transport.release.signal()
        XCTAssertEqual(transport.stopped.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(transport.started)
    }
}

private final class DelayedAuthorization: HelperTransport {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    var started = false
    func authorize(binary: URL, digest: String) throws {
        entered.signal(); _ = release.wait(timeout: .now() + 3)
    }
    func send(_ request: HelperRequest) throws -> HelperResponse {
        switch request.operation {
        case .status: throw ControlClientError.notRunning
        case .start: started = true
        case .stop: stopped.signal()
        case .shutdown: break
        }
        return HelperResponse(status: MihomoStatus(), digest: "test")
    }
}
