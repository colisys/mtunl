import Foundation
import Darwin

/// Login-time autostart for the app through a per-user LaunchAgent.
/// Starts MTunl.app which will launch the daemon via ensureDaemon().
public enum LaunchAgent {
    public static let label = "local.mtunl.daemon"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mtunl.log").path
    }

    /// Launches MTunl.app at login. The app will start the daemon if needed.
    /// `executable` is the path to MTunl.app/Contents/MacOS/MTunl.
    public static func plist(executable: String) throws -> Data {
        guard let appPath = executable.components(separatedBy: "/Contents/MacOS/").first,
              appPath.hasSuffix(".app") else {
            throw TunnelValidationError("可执行文件路径必须在 .app bundle 中")
        }
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func install(executable: String) throws {
        guard executable.hasPrefix("/") else { throw TunnelValidationError("可执行文件路径必须是绝对路径") }
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plist(executable: executable).write(to: plistURL, options: .atomic)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"]) // reload if already loaded
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw TunnelValidationError("launchctl 失败：\(result.output)")
        }
    }

    public static func uninstall() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
