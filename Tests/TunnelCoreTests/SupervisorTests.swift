import XCTest
@testable import TunnelCore

final class SupervisorTests: XCTestCase {
    private func config(_ name: String, port: Int = 9000) -> TunnelConfig {
        TunnelConfig(name: name, kind: .local, host: "h", listenPort: port, targetHost: "t", targetPort: 1)
    }

    private func supervisor(
        executable: String, arguments: [String],
        backoff: Backoff = Backoff(base: 0.1, cap: 0.2, healthyUptime: 60),
        portInUse: @escaping @Sendable (String, Int) -> Bool = { _, _ in false }
    ) -> TunnelSupervisor {
        TunnelSupervisor(backoff: backoff, stableAfter: 0.2, portInUse: portInUse) { _ in
            ToolCommand(executable: executable, arguments: arguments)
        }
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    func testStartReachesRunningThenStops() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        XCTAssertNotNil(sup.statuses().first?.pid)
        sup.stop(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .stopped })
        XCTAssertNil(sup.statuses().first?.pid)
    }

    func testCrashingProcessIsRetriedWithWaitingState() {
        let sup = supervisor(executable: "/usr/bin/false", arguments: [])
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { (sup.statuses().first?.restarts ?? 0) >= 2 })
        let state = sup.statuses().first?.state
        XCTAssertTrue(state == .waiting || state == .starting)
        sup.shutdown()
    }

    func testPortConflictWaitsWithoutLaunching() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"], portInUse: { _, _ in true })
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .waiting })
        XCTAssertNil(sup.statuses().first?.pid)
        XCTAssertTrue(sup.statuses().first?.message?.contains("已被占用") ?? false)
        sup.shutdown()
    }

    func testResolverFailureIsFailedAndNotRetried() {
        let sup = TunnelSupervisor(backoff: Backoff(base: 0.1, cap: 0.2)) { _ in
            throw CommandBuilderError.toolNotFound("socat")
        }
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .failed })
        usleep(400_000)
        XCTAssertEqual(sup.statuses().first?.restarts, 0)
    }

    func testRestartReplacesProcess() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        let first = sup.statuses().first?.pid
        sup.restart(item.id)
        XCTAssertTrue(wait {
            let status = sup.statuses().first
            return status?.pid != nil && status?.pid != first
        })
        sup.shutdown()
    }

    func testApplyRemovesTunnelAndStopsItsProcess() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        sup.apply([])
        XCTAssertTrue(wait { sup.statuses().isEmpty })
    }

    func testApplyChangedConfigRestartsRunningTunnel() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        var item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        let first = sup.statuses().first?.pid
        item.listenPort = 9001
        sup.apply([item])
        XCTAssertTrue(wait {
            let status = sup.statuses().first
            return status?.pid != nil && status?.pid != first
        })
        sup.shutdown()
    }

    func testAutoStartOnlyStartsFlaggedTunnels() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        var auto = config("auto", port: 9000)
        auto.autoStart = true
        let manual = config("manual", port: 9001)
        sup.apply([auto, manual])
        sup.startAutoStart()
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        XCTAssertEqual(sup.statuses().last?.state, .stopped)
        sup.shutdown()
    }

    func testShutdownLeavesNoChildren() {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        let item = config("a")
        sup.apply([item])
        sup.start(item.id)
        XCTAssertTrue(wait { sup.statuses().first?.pid != nil })
        sup.shutdown()
        XCTAssertNil(sup.statuses().first?.pid)
    }

    func testHandlerResolvesByNameAndRejectsUnknown() throws {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        let item = config("Web")
        sup.apply([item])
        let store = ConfigStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).json"))
        let handler = ControlHandler(supervisor: sup, store: store) {}
        XCTAssertTrue(handler.handle(ControlRequest(command: "start", target: "web")).success)
        XCTAssertFalse(handler.handle(ControlRequest(command: "start", target: "nope")).success)
        XCTAssertFalse(handler.handle(ControlRequest(command: "start")).success)
        XCTAssertFalse(handler.handle(ControlRequest(command: "bogus")).success)
        sup.shutdown()
    }

    func testServerClientRoundTrip() throws {
        let sup = supervisor(executable: "/bin/sleep", arguments: ["30"])
        let directory = "/tmp/mtunl-test-\(UUID().uuidString.prefix(8))"
        let path = directory + "/ctl.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = ConfigStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("y-\(UUID().uuidString).json"))
        let server = ControlServer(handler: ControlHandler(supervisor: sup, store: store) {}, path: path)
        try server.start()
        defer { server.stop() }

        let client = ControlClient(path: path)
        XCTAssertTrue(client.isRunning())
        XCTAssertEqual(try client.send(ControlRequest(command: "status")).statuses?.count, 0)

        var attrs = stat()
        XCTAssertEqual(stat(path, &attrs), 0)
        XCTAssertEqual(attrs.st_mode & 0o777, 0o600)

        let second = ControlServer(handler: ControlHandler(supervisor: sup, store: store) {}, path: path)
        XCTAssertThrowsError(try second.start())
        server.stop()
        XCTAssertFalse(client.isRunning())
    }
}
