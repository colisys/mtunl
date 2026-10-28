import Foundation
import Security

/// Keychain-backed credential storage for MTunl SSH connections to
/// password-authenticated servers.
///
/// The password is stored as a generic password item and used in two ways:
/// - Tunnels: when the bridge reports a password request (key auth failed),
///   the supervisor auto-supplies the stored password through the existing
///   anonymous secret pipe.
/// - SFTP: handed to the system `ssh`/`sftp` processes through the
///   `SSH_ASKPASS` mechanism (`SSH_ASKPASS_REQUIRE=force`).
/// In both paths the secret never appears in argv and is never written to
/// disk; the askpass helper reads it from an inherited environment variable.
public enum MTunlKeychain {
    private static let service = "MTunl SSH"

    public static func account(for config: TunnelConfig) -> String {
        if let user = config.user, !user.isEmpty {
            return "\(user)@\(config.host)"
        }
        return config.host
    }

    // MARK: - Keychain items

    public static func savePassword(_ password: String, for config: TunnelConfig) -> Bool {
        let account = account(for: config)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace any existing item for this account.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func loadPassword(for config: TunnelConfig) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: config),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    public static func hasPassword(for config: TunnelConfig) -> Bool {
        loadPassword(for: config) != nil
    }

    public static func deletePassword(for config: TunnelConfig) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: config),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - SSH_ASKPASS setup

    /// Installs the askpass helper script and returns environment variables
    /// that make `ssh`/`sftp` fetch the keychain password automatically.
    /// Returns `nil` when no password is stored, leaving normal
    /// key/agent/control-socket authentication untouched.
    public static func askpassEnvironment(for config: TunnelConfig) throws -> [String: String]? {
        guard let password = loadPassword(for: config) else { return nil }

        let scriptPath = try Self.askpassScriptPath()
        let script = "#!/bin/sh\nprintf '%s\\n' \"$MTUNL_PASS\"\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: scriptPath) {
            try script.data(using: .utf8)!.write(to: URL(fileURLWithPath: scriptPath))
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)
        }

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = scriptPath
        // macOS ships OpenSSH >= 8.4, so forcing askpass without detaching
        // from the tty is supported.
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? "mtunl"
        env["MTUNL_PASS"] = password
        return env
    }

    /// Removes the askpass helper script. Call after the child process exits.
    public static func cleanupAskpassScript() {
        guard let path = try? askpassScriptPath() else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func askpassScriptPath() throws -> String {
        let dir = NSTemporaryDirectory() + "/mtunl-askpass-\(getuid())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir + "/askpass.sh"
    }
}
