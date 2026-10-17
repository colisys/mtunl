import XCTest
@testable import TunnelCore

final class CommandBuilderTests: XCTestCase {
    private func base(_ kind: TunnelKind) -> TunnelConfig {
        TunnelConfig(
            name: "t", kind: kind, host: "example.com", user: "me", sshPort: 2222,
            bindAddress: "127.0.0.1", listenPort: 8080, targetHost: "db.internal", targetPort: 5432
        )
    }

    func testLocalForward() throws {
        let command = try CommandBuilder.command(for: base(.local))
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("-N"))
        XCTAssertTrue(command.arguments.contains("ExitOnForwardFailure=yes"))
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "-L"))
        XCTAssertEqual(command.arguments[index + 1], "127.0.0.1:8080:db.internal:5432")
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--", "me@example.com"])
        XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "-p")! + 1], "2222")
    }

    func testRemoteForward() throws {
        let command = try CommandBuilder.command(for: base(.remote))
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "-R"))
        XCTAssertEqual(command.arguments[index + 1], "127.0.0.1:8080:db.internal:5432")
    }

    func testDynamicForward() throws {
        let command = try CommandBuilder.command(for: base(.dynamic))
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "-D"))
        XCTAssertEqual(command.arguments[index + 1], "127.0.0.1:8080")
        XCTAssertFalse(command.arguments.contains("-L"))
    }

    func testIPv6TargetIsBracketed() throws {
        var config = base(.local)
        config.targetHost = "::1"
        let command = try CommandBuilder.command(for: config)
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "-L"))
        XCTAssertEqual(command.arguments[index + 1], "127.0.0.1:8080:[::1]:5432")
    }

    func testRelayUsesSocat() throws {
        let command = try CommandBuilder.command(for: base(.relay), socatPath: "/usr/local/bin/socat")
        XCTAssertEqual(command.executable, "/usr/local/bin/socat")
        XCTAssertEqual(command.arguments, [
            "TCP-LISTEN:8080,bind=127.0.0.1,reuseaddr,fork", "TCP:db.internal:5432",
        ])
    }

    func testIdentityAndJump() throws {
        var config = base(.local)
        config.identityFile = "~/.ssh/id_ed25519"
        config.jumpHost = "bastion"
        let args = try CommandBuilder.command(for: config).arguments
        XCTAssertEqual(args[args.firstIndex(of: "-i")! + 1], "~/.ssh/id_ed25519")
        XCTAssertEqual(args[args.firstIndex(of: "-J")! + 1], "bastion")
    }

    func testShellQuoting() {
        XCTAssertEqual(ToolCommand.quote("plain-1.2"), "plain-1.2")
        XCTAssertEqual(ToolCommand.quote("a b"), "'a b'")
        XCTAssertEqual(ToolCommand.quote("it's"), "'it'\\''s'")
    }
}
