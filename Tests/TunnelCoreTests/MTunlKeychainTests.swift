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

    func testSFTPCommandsNeverReferenceAskpassOrPasswords() throws {
        // SFTP multiplexes over the ControlMaster: its command lines must never
        // set up credential plumbing (askpass, env secrets) of any kind.
        let config = makeConfig(host: "sftp-auth-test.invalid")
        XCTAssertTrue(MTunlKeychain.savePassword("pw", for: config))
        defer { MTunlKeychain.deletePassword(for: config) }

        let sftpArguments = try SFTPClient.sftpCommand(for: config).joined(separator: " ")
        XCTAssertFalse(sftpArguments.lowercased().contains("askpass"))
        XCTAssertFalse(sftpArguments.lowercased().contains("preferredauthentications"))
        XCTAssertTrue(sftpArguments.contains("ControlPath=/tmp/mtunl-"))
    }
}
