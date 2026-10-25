import XCTest
@testable import TunnelCore

final class LaunchAgentTests: XCTestCase {
    func testPlistRunsServeAtLoadAndRestartsOnlyAfterCrash() throws {
        let data = try LaunchAgent.plist(executable: "/Apps/MTunl.app/Contents/MacOS/mtunlctl")
        let dictionary = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(dictionary["Label"] as? String, LaunchAgent.label)
        XCTAssertEqual(dictionary["ProgramArguments"] as? [String],
                       ["/Apps/MTunl.app/Contents/MacOS/mtunlctl", "serve"])
        XCTAssertEqual(dictionary["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((dictionary["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false)
    }

    func testInstallRejectsRelativeExecutable() {
        XCTAssertThrowsError(try LaunchAgent.install(executable: "mtunlctl"))
    }
}
