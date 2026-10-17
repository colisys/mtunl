import XCTest
@testable import TunnelCore

final class PasswordSessionTests: XCTestCase {
    func testPasswordStartCannotActivateLegacyDaemonPath() throws {
        let request = ControlRequest(command: "start", target: "test", oneTimePassword: UUID().uuidString)
        XCTAssertEqual(request.command, "startSession")
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.command, "startSession")
        XCTAssertEqual(ControlRequest(command: "start").command, "start")
        let hostRequest = ControlRequest(command: "trustHostKey", target: "test", hostKeyRequestID: UUID())
        let hostDecoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(hostRequest))
        XCTAssertEqual(hostDecoded.hostKeyRequestID, hostRequest.hostKeyRequestID)
    }

    func testHostKeyEventParsesOnlyWellFormedFingerprint() {
        let line = "MTUNL_HOSTKEY [example.com]:2222 SHA256:AbCdEf0123456789+/"
        let key = SSHHostKey(event: line)
        XCTAssertEqual(key?.host, "[example.com]:2222")
        XCTAssertEqual(key?.fingerprint, "SHA256:AbCdEf0123456789+/")
        XCTAssertEqual(SSHHostKey(event: "MTUNL_HOSTKEY [alias]:22 SHA256:AbCdEf0123456789+/")?.host, "[alias]:22")
        for malformed in ["MTUNL_HOSTKEY host SHA256:", "MTUNL_HOSTKEY host MD5:1234",
                          "MTUNL_HOSTKEY host SHA256:bad!", "MTUNL_HOSTKEY host name SHA256:abc"] {
            XCTAssertNil(SSHHostKey(event: malformed), malformed)
        }
    }

    func testTargetEventParsesOnlyWellFormedIdentity() {
        let target = SSHTarget(event: "MTUNL_TARGET root 178.83.203.20 22")
        XCTAssertEqual(target, SSHTarget(event: "MTUNL_TARGET root 178.83.203.20 22"))
        XCTAssertEqual(target?.user, "root")
        XCTAssertEqual(target?.host, "178.83.203.20")
        XCTAssertEqual(target?.port, "22")
        for malformed in ["MTUNL_TARGET  host 22", "MTUNL_TARGET root host 0", "MTUNL_TARGET root host 70000",
                          "MTUNL_TARGET root host 22 extra", "MTUNL_TARGET root host", "MTUNL_AUTHENTICATED"] {
            XCTAssertNil(SSHTarget(event: malformed), malformed)
        }
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    // Fake bridge: the first run (no --expect) reports a target and asks for a password; a
    // password run (--expect first) behaves per `body`. Real pipe/PTY transport is tested offline in Python.
    private func fixture(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mtunl-fixture-\(UUID())")
        try Data(("#!/bin/sh\n/usr/bin/true\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func passwordConfig(host: String = "alias") -> TunnelConfig {
        TunnelConfig(name: "test", kind: .dynamic, host: host, listenPort: 12345, sshAuthMethod: .password)
    }

    private func requestPassword(_ sup: TunnelSupervisor, _ config: TunnelConfig, secret: String) throws {
        sup.apply([config]); sup.start(config.id)
        XCTAssertTrue(wait { sup.statuses().first?.passwordRequestID != nil })
        let token = try XCTUnwrap(sup.statuses().first?.passwordRequestID)
        XCTAssertTrue(sup.supplyPassword(config.id, requestID: token, password: secret))
    }

    func testCredentialSurvivesRunningAndReconnectThenStopClears() throws {
        let bridge = try fixture("if [ \"$1\" = --expect ]; then printf 'MTUNL_AUTHENTICATED\\n' >&2; exec /bin/sleep 0.2; fi\nprintf 'MTUNL_TARGET root alias 22\\n' >&2\nexit 79")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(backoff: Backoff(base: 0.02, cap: 0.02), stableAfter: 0.01,
                                   portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = passwordConfig()
        let secret = UUID().uuidString
        try requestPassword(sup, config, secret: secret)
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        XCTAssertEqual(sup.queue.sync { sup.entries[config.id]?.oneTimePassword }, secret)
        // Repeated starts must not erase the active session credential.
        sup.start(config.id)
        XCTAssertTrue(wait { (sup.statuses().first?.restarts ?? 0) >= 2 })
        XCTAssertEqual(sup.queue.sync { sup.entries[config.id]?.oneTimePassword }, secret)
        sup.restart(config.id)
        XCTAssertEqual(sup.queue.sync { sup.entries[config.id]?.oneTimePassword }, secret)
        let status = try JSONEncoder().encode(sup.statuses())
        XCTAssertFalse(String(decoding: status, as: UTF8.self).contains(secret))
        sup.stop(config.id)
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.sshTarget })
    }

    func testAuthenticationAndUnsupportedPromptClearWithoutRetry() throws {
        for code in [77, 78] {
            let bridge = try fixture("if [ \"$1\" = --expect ]; then exit \(code); fi\nprintf 'MTUNL_TARGET root alias 22\\n' >&2\nexit 79")
            defer { try? FileManager.default.removeItem(at: bridge) }
            let sup = TunnelSupervisor(stableAfter: 0.01, portInUse: { _, _ in false }, bridgePath: bridge.path)
            defer { sup.shutdown() }
            let config = passwordConfig()
            try requestPassword(sup, config, secret: UUID().uuidString)
            XCTAssertTrue(wait { sup.statuses().first?.state == .failed && sup.statuses().first?.passwordRequestID == nil })
            XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
            XCTAssertEqual(sup.statuses().first?.restarts, 0)
        }
    }

    func testRemovalCancelsWaitingSessionAndClearsCapturedEntry() {
        let sup = TunnelSupervisor(portInUse: { _, _ in true }, bridgePath: "/usr/bin/true")
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345)
        sup.apply([config])
        sup.queue.sync { sup.entries[config.id]?.sshTarget = SSHTarget(event: "MTUNL_TARGET root alias 22") }
        sup.start(config.id, oneTimePassword: UUID().uuidString)
        let entry = sup.queue.sync { sup.entries[config.id]! }
        XCTAssertEqual(sup.statuses().first?.state, .waiting)
        sup.apply([])
        sup.queue.sync {
            XCTAssertNil(entry.oneTimePassword)
            XCTAssertNil(entry.retryTimer)
            XCTAssertFalse(entry.desired)
        }
    }

    func testConfigChangeClearsWaitingCredentialAndObservedTarget() {
        let sup = TunnelSupervisor(portInUse: { _, _ in true }, bridgePath: "/usr/bin/true")
        defer { sup.shutdown() }
        var config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345)
        sup.apply([config])
        sup.queue.sync { sup.entries[config.id]?.sshTarget = SSHTarget(event: "MTUNL_TARGET root alias 22") }
        sup.start(config.id, oneTimePassword: UUID().uuidString)
        XCTAssertNotNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
        config.host = "other.invalid"
        sup.apply([config])
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.sshTarget })
    }

    func testOnlyExplicitPasswordRequirementIssuesUIChallenge() throws {
        for code in [79, 77, 78, 255] {
            let bridge = try fixture("printf 'MTUNL_TARGET root alias 22\\n' >&2\nexit \(code)")
            defer { try? FileManager.default.removeItem(at: bridge) }
            let sup = TunnelSupervisor(backoff: Backoff(base: 5, cap: 5), portInUse: { _, _ in false }, bridgePath: bridge.path)
            defer { sup.shutdown() }
            let config = passwordConfig()
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

    func testUnknownHostKeyRequiresMatchingRequestAndTrustRelaunches() throws {
        let fingerprint = "SHA256:AbCdEf0123456789+/"
        let bridge = try fixture("if [ \"$1\" = --accept ]; then printf 'MTUNL_AUTHENTICATED\\n' >&2; exec /bin/sleep 2; fi\nprintf 'MTUNL_HOSTKEY [alias]:22 \(fingerprint)\\n' >&2\nexit 80")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(backoff: Backoff(base: 5, cap: 5), portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345)
        sup.apply([config]); sup.start(config.id)
        XCTAssertTrue(wait { sup.statuses().first?.hostKey != nil })
        let challenge = try XCTUnwrap(sup.statuses().first?.hostKey)
        XCTAssertEqual(challenge.host, "[alias]:22")
        XCTAssertEqual(challenge.fingerprint, fingerprint)
        XCTAssertFalse(sup.trustHostKey(config.id, requestID: UUID()))
        XCTAssertTrue(sup.trustHostKey(config.id, requestID: challenge.requestID))
        XCTAssertTrue(wait { sup.statuses().first?.state == .running })
        sup.queue.sync {
            let args = sup.entries[config.id]?.process?.arguments ?? []
            XCTAssertTrue(args.starts(with: ["--accept", "[alias]:22", fingerprint, "--"]))
            XCTAssertNil(sup.entries[config.id]?.hostKeyRequest)
            XCTAssertEqual(sup.entries[config.id]?.acceptedHostKeys.count, 1)
        }
        sup.stop(config.id)
        XCTAssertTrue(sup.queue.sync { sup.entries[config.id]?.acceptedHostKeys.isEmpty == true })
    }

    func testChangedHostKeyStopsWithoutRetryOrTrustRequest() throws {
        let bridge = try fixture("printf 'SSH host key verification failed\\n' >&2\nexit 81")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(backoff: Backoff(base: 5, cap: 5), portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345)
        sup.apply([config]); sup.start(config.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .failed })
        XCTAssertNil(sup.statuses().first?.hostKey)
        XCTAssertEqual(sup.statuses().first?.restarts, 0)
        XCTAssertTrue(sup.statuses().first?.message?.contains("指纹已变化") == true)
    }

    func testPasswordRequestWithoutObservedTargetIsRefused() throws {
        let bridge = try fixture("exit 79")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(backoff: Backoff(base: 5, cap: 5), portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = passwordConfig()
        sup.apply([config]); sup.start(config.id)
        XCTAssertTrue(wait { sup.statuses().first?.state == .failed })
        XCTAssertNil(sup.statuses().first?.passwordRequestID)
    }

    func testPasswordIsBoundToObservedTargetAndNeverLeakedToArguments() throws {
        let bridge = try fixture("if [ \"$1\" = --expect ]; then exec /bin/sleep 5; fi\nprintf 'MTUNL_TARGET root alias 22\\n' >&2\nexit 79")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = passwordConfig()
        let secret = UUID().uuidString
        try requestPassword(sup, config, secret: secret)
        XCTAssertFalse(sup.supplyPassword(config.id, requestID: UUID(), password: secret))
        XCTAssertTrue(wait { sup.queue.sync { sup.entries[config.id]?.process != nil } })
        sup.queue.sync {
            let arguments = sup.entries[config.id]?.process?.arguments ?? []
            XCTAssertEqual(Array(arguments.prefix(5)), ["--expect", "root", "alias", "22", "--"])
            XCTAssertFalse(arguments.contains(secret))
        }
        sup.stop(config.id)
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.sshTarget })
    }

    func testPasswordStartWithoutObservedTargetFailsClosed() {
        let sup = TunnelSupervisor(portInUse: { _, _ in false }, bridgePath: "/usr/bin/true")
        defer { sup.shutdown() }
        let config = TunnelConfig(name: "test", kind: .dynamic, host: "alias", listenPort: 12345)
        sup.apply([config]); sup.start(config.id, oneTimePassword: UUID().uuidString)
        XCTAssertEqual(sup.statuses().first?.state, .failed)
        XCTAssertNil(sup.queue.sync { sup.entries[config.id]?.oneTimePassword })
        XCTAssertNil(sup.statuses().first?.pid)
    }

    func testSSHSurvivalDoesNotMeanAuthenticationAndEventsAreFramed() throws {
        let bridge = try fixture("exec /bin/sleep 5")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let sup = TunnelSupervisor(stableAfter: 0.01, portInUse: { _, _ in false }, bridgePath: bridge.path)
        defer { sup.shutdown() }
        let config = passwordConfig()
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
