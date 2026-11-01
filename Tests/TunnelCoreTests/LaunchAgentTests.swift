import XCTest
@testable import TunnelCore

final class LaunchAgentTests: XCTestCase {
    func testPlistLaunchesAppAtLogin() throws {
        let data = try LaunchAgent.plist(executable: "/Applications/MTunl.app/Contents/MacOS/MTunl")
        let dictionary = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(dictionary["Label"] as? String, LaunchAgent.label)
        XCTAssertEqual(dictionary["ProgramArguments"] as? [String],
                       ["/usr/bin/open", "-a", "/Applications/MTunl.app"])
        XCTAssertEqual(dictionary["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(dictionary["ProcessType"] as? String, "Interactive")
        // Should not have KeepAlive, StandardOutPath, etc. since it launches the app, not the daemon
        XCTAssertNil(dictionary["KeepAlive"])
        XCTAssertNil(dictionary["StandardOutPath"])
    }

    func testInstallRejectsRelativeExecutable() {
        XCTAssertThrowsError(try LaunchAgent.install(executable: "MTunl"))
    }

    func testInstallRejectsNonAppBundleExecutable() {
        XCTAssertThrowsError(try LaunchAgent.install(executable: "/usr/bin/mtunlctl"))
    }
}
