import XCTest
@testable import TunnelCore

final class ValidationTests: XCTestCase {
    private func valid() -> TunnelConfig {
        TunnelConfig(name: "db", kind: .local, host: "example.com", listenPort: 5432,
                     targetHost: "localhost", targetPort: 5432)
    }

    func testValidConfigPasses() throws {
        try valid().validate()
    }

    func testHostCannotLookLikeAnOption() {
        var config = valid()
        config.host = "-oProxyCommand=evil"
        XCTAssertThrowsError(try config.validate())
        config.host = "example.com"
        config.user = "-x"
        XCTAssertThrowsError(try config.validate())
    }

    func testJumpHostRejectsOptionHop() {
        var config = valid()
        config.jumpHost = "good,-oProxyCommand=x"
        XCTAssertThrowsError(try config.validate())
        config.jumpHost = "good,other"
        XCTAssertNoThrow(try config.validate())
    }

    func testPortRanges() {
        var config = valid()
        config.listenPort = 0
        XCTAssertThrowsError(try config.validate())
        config.listenPort = 70000
        XCTAssertThrowsError(try config.validate())
        config = valid()
        config.targetPort = 0
        XCTAssertThrowsError(try config.validate())
    }

    func testDynamicNeedsNoTarget() throws {
        var config = valid()
        config.kind = .dynamic
        config.targetHost = ""
        config.targetPort = 0
        try config.validate()
    }

    func testIdentityFileMustBeAbsoluteOrHome() {
        var config = valid()
        config.identityFile = "relative/key"
        XCTAssertThrowsError(try config.validate())
        config.identityFile = "~/.ssh/id_ed25519"
        XCTAssertNoThrow(try config.validate())
    }

    func testRelayRejectsIPv6() {
        var config = valid()
        config.kind = .relay
        config.targetHost = "::1"
        XCTAssertThrowsError(try config.validate())
    }

    func testDuplicateNamesAndListeners() throws {
        var other = valid()
        other.id = UUID()
        other.listenPort = 6000
        XCTAssertThrowsError(try TunnelConfig.validate(all: [valid(), other.withName("DB")]))
        var clash = valid()
        clash.id = UUID()
        clash.name = "other"
        XCTAssertThrowsError(try TunnelConfig.validate(all: [valid(), clash]))
        try TunnelConfig.validate(all: [valid(), other.withName("other")])
    }

    func testRemoteListenerDoesNotClashWithLocal() throws {
        var remote = valid()
        remote.id = UUID()
        remote.name = "remote"
        remote.kind = .remote
        try TunnelConfig.validate(all: [valid(), remote])
    }

    func testExposureFlag() {
        var config = valid()
        XCTAssertFalse(config.exposesToNetwork)
        config.bindAddress = "0.0.0.0"
        XCTAssertTrue(config.exposesToNetwork)
    }

    func testBackoffGrowsAndCaps() {
        let backoff = Backoff()
        XCTAssertEqual(backoff.delay(forAttempt: 1), 1)
        XCTAssertEqual(backoff.delay(forAttempt: 2), 2)
        XCTAssertEqual(backoff.delay(forAttempt: 5), 16)
        XCTAssertEqual(backoff.delay(forAttempt: 6), 30)
        XCTAssertEqual(backoff.delay(forAttempt: 100), 30)
    }

    func testStoreRoundTripAndCorruption() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtunl-test-\(UUID().uuidString)/tunnels.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigStore(url: url)
        XCTAssertEqual(try store.load(), [])
        try store.save([valid()])
        XCTAssertEqual(try store.load().count, 1)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }
}

private extension TunnelConfig {
    func withName(_ name: String) -> TunnelConfig {
        var copy = self
        copy.name = name
        return copy
    }
}
