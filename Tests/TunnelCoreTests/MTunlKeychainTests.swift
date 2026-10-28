import XCTest
@testable import TunnelCore

final class MTunlKeychainTests: XCTestCase {
    private func makeConfig(host: String) -> TunnelConfig {
        TunnelConfig(name: "test-\(host)", host: host, user: "alice")
    }

    func testSaveLoadDeleteRoundTrip() {
        let config = makeConfig(host: "keychain-test.invalid")
        defer { MTunlKeychain.deletePassword(for: config) }

        // Clean state
        MTunlKeychain.deletePassword(for: config)
        XCTAssertNil(MTunlKeychain.loadPassword(for: config))

        XCTAssertTrue(MTunlKeychain.savePassword("s3cret-密码", for: config))
        XCTAssertEqual(MTunlKeychain.loadPassword(for: config), "s3cret-密码")
        XCTAssertTrue(MTunlKeychain.hasPassword(for: config))

        // Overwrite
        XCTAssertTrue(MTunlKeychain.savePassword("new-pass", for: config))
        XCTAssertEqual(MTunlKeychain.loadPassword(for: config), "new-pass")

        XCTAssertTrue(MTunlKeychain.deletePassword(for: config))
        XCTAssertNil(MTunlKeychain.loadPassword(for: config))
        XCTAssertFalse(MTunlKeychain.hasPassword(for: config))
    }

    func testAccountNameUsesUserAndHost() {
        let config = makeConfig(host: "example.com")
        XCTAssertEqual(MTunlKeychain.account(for: config), "alice@example.com")

        var noUser = config
        noUser.user = nil
        XCTAssertEqual(MTunlKeychain.account(for: noUser), "example.com")
    }

    func testAskpassEnvironmentOnlyWhenPasswordStored() throws {
        let config = makeConfig(host: "keychain-test2.invalid")
        defer { MTunlKeychain.deletePassword(for: config) }

        MTunlKeychain.deletePassword(for: config)
        XCTAssertNil(try MTunlKeychain.askpassEnvironment(for: config))

        XCTAssertTrue(MTunlKeychain.savePassword("pw", for: config))
        let env = try MTunlKeychain.askpassEnvironment(for: config)
        XCTAssertNotNil(env)
        XCTAssertEqual(env?["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertNotNil(env?["SSH_ASKPASS"])
        // The askpass script itself must not contain the secret
        let script = try String(contentsOfFile: env!["SSH_ASKPASS"]!, encoding: .utf8)
        XCTAssertFalse(script.contains("pw"))
        MTunlKeychain.cleanupAskpassScript()
    }
}
