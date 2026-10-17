import XCTest
@testable import TunnelCore

final class PasswordSessionTests: XCTestCase {
    func testPasswordStartCannotActivateLegacyDaemonPath() throws {
        let request = ControlRequest(command: "start", target: "test", oneTimePassword: UUID().uuidString)
        XCTAssertEqual(request.command, "startSession")
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.command, "startSession")
        XCTAssertEqual(ControlRequest(command: "start").command, "start")
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    // Lifecycle-only fake bridge ignores stdin; real pipe/PTY transport is tested offline in Python.
    private func fixture(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mtunl-fixture-\(UUID())")
        try Data(("#!/bin/sh\n/usr/bin/true\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testCredentialSurvivesRunningAndReconnectThenStopClears() throws {
        let bridge = try fixture("printf 'MTUNL_AUTHENTICATED\\n' >&2\nexec /bin/sleep 0.2")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(backoff: Backoff(base: 0.02, cap: 0.02), stableAfter: 0.01,
                                   portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "example.invalid", listenPort: 12345)
        let secret = UUID().uuidString
        sup.apply([config]); sup.start(config.id, oneTimePassword: secret)
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        XCTAssertEqual(sup.queue.sync { sup.entries[config.id]?.oneTimePassword }, secret)
        // Repeated starts must not erase the active session credential.
        sup.start(config.id, oneTimePassword: nil)
        XCTAssertTrue(wait { (sup.statuses().first?.restarts ?? 0) >= 2 })
        XCTAssertEqual(sup.queue.sync { sup.entries[config.id]?.oneTimePassword }, secret)
        sup.restart(config.id)
        XCTAssertEqual(sup.queue.sync { sup.entries[config.id]?.oneTimePassword }, secret)
        let status = try JSONEncoder().encode(sup.statuses())
        XCTAssertFalse(String(decoding: status, as: UTF8.self).contains(secret))
        sup.stop(config.id)
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
    }

    func testAuthenticationAndUnsupportedPromptClearWithoutRetry() throws {
        for code in [77, 78] {
            let bridge = try fixture("exit \(code)")
            defer { try? FileManager.default.removeItem(at: bridge) }
            let sup = TunnelSupervisor(stableAfter: 0.01, portInUse: { _, _ in false }, bridgePath: bridge.path)
            defer { sup.shutdown() }
            let config = TunnelConfig(name: "test", kind: .dynamic, host: "example.invalid", listenPort: 12345)
            sup.apply([config]); sup.start(config.id, oneTimePassword: UUID().uuidString)
            XCTAssertTrue(wait { sup.statuses().first?.state == .failed })
            XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
            XCTAssertEqual(sup.statuses().first?.restarts, 0)
        }
    }

    func testRemovalCancelsWaitingSessionAndClearsCapturedEntry() {
        let sup = TunnelSupervisor(portInUse: { _, _ in true }, bridgePath: "/usr/bin/true")
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "example.invalid", listenPort: 12345)
        sup.apply([config]); sup.start(config.id, oneTimePassword: UUID().uuidString)
        let entry = sup.queue.sync { sup.entries[config.id]! }
        XCTAssertEqual(sup.statuses().first?.state, .waiting)
        sup.apply([])
        sup.queue.sync {
            XCTAssertNil(entry.oneTimePassword)
            XCTAssertNil(entry.retryTimer)
            XCTAssertFalse(entry.desired)
        }
    }

    func testConfigChangeClearsWaitingCredential() {
        let sup = TunnelSupervisor(portInUse: { _, _ in true }, bridgePath: "/usr/bin/true")
        defer { sup.shutdown() }
        var config = TunnelConfig(name: "test", kind: .dynamic, host: "example.invalid", listenPort: 12345)
        sup.apply([config]); sup.start(config.id, oneTimePassword: UUID().uuidString)
        XCTAssertNotNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
        config.host = "other.invalid"
        sup.apply([config])
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
    }

    func testOnlyExplicitPasswordRequirementIssuesUIChallenge() throws {
        for code in [79, 77, 78, 255] {
            let bridge = try fixture("exit \(code)")
            defer { try? FileManager.default.removeItem(at: bridge) }
            let sup = TunnelSupervisor(backoff: Backoff(base: 5, cap: 5), portInUse: { _, _ in false }, bridgePath: bridge.path)
            defer { sup.shutdown() }
            let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345, sshAuthMethod: .password)
            sup.apply([config]); sup.start(config.id)
            XCTAssertTrue(wait { sup.statuses().first?.state != .starting })
            XCTAssertEqual(sup.statuses().first?.passwordRequestID != nil, code == 79)
            if code == 79 {
                let token = try XCTUnwrap(sup.statuses().first?.passwordRequestID)
                XCTAssertFalse(sup.supplyPassword(config.id, requestID: UUID(), password: "unused"))
                sup.stop(config.id)
                XCTAssertFalse(sup.supplyPassword(config.id, requestID: token, password: "unused"))
                XCTAssertNil(sup.statuses().first?.passwordRequestID)
            }
        }
    }

    func testPasswordCanBeSuppliedAndIsNeverLeakedToArguments() throws {
        let bridge = try fixture("/bin/sleep 0.1\nexit 79")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345, sshAuthMethod: .password)
        sup.apply([config]); sup.start(config.id)
        XCTAssertTrue(wait { sup.statuses().first?.passwordRequestID != nil })
        let token = try XCTUnwrap(sup.statuses().first?.passwordRequestID)
        let secret = UUID().uuidString
        XCTAssertTrue(sup.supplyPassword(config.id, requestID: token, password: secret))
        XCTAssertFalse(sup.supplyPassword(config.id, requestID: token, password: secret))
        sup.queue.sync {
            let entry = sup.entries[config.id]!
            XCTAssertFalse(entry.process?.arguments?.contains(secret) ?? true)
        }
        sup.stop(config.id)
    }

    func testSSHSurvivalDoesNotMeanAuthenticationAndEventsAreFramed() throws {
        let bridge = try fixture("exec /bin/sleep 5")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(stableAfter: 0.01, portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345, sshAuthMethod: .password)
        sup.apply([config]); sup.start(config.id)
        usleep(100_000)
        XCTAssertEqual(sup.statuses().first?.state, .starting)
        XCTAssertNil(sup.statuses().first?.passwordRequestID)
        sup.queue.sync {
            let entry = sup.entries[config.id]!
            TunnelSupervisor.append(Data("MTUNL_AUTHEN".utf8), to: entry)
            XCTAssertEqual(entry.state, .starting)
            TunnelSupervisor.append(Data("TICATED\n".utf8), to: entry)
            XCTAssertEqual(entry.state, .running)
            TunnelSupervisor.append(Data("untrusted-output\n".utf8), to: entry)
            XCTAssertTrue(entry.log.isEmpty)
        }
        XCTAssertNil(sup.statuses().first?.passwordRequestID)
    }

    func testInvalidPasswordAndMissingBridgeFailClosed() {
        for (path, secret) in [("/missing/mtunl-ssh-bridge", "test"), ("/usr/bin/true", "bad\ninput")] {
            let sup = TunnelSupervisor(portInUse: { _, _ in false }, bridgePath: path)
            let config = TunnelConfig(name: "test", kind: .dynamic, host: "example.invalid", listenPort: 12345)
            sup.apply([config]); sup.start(config.id, oneTimePassword: secret)
            XCTAssertEqual(sup.statuses().first?.state, .failed)
            XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
            XCTAssertNil(sup.statuses().first?.pid)
        }
    }
}
