import Foundation
import Security

/// Keychain-backed credential storage for MTunl SSH connections to
/// password-authenticated servers.
///
/// The password is stored as a generic password item and used by the tunnel
/// bridge: when the bridge reports a password request (key auth failed), the
/// supervisor auto-supplies the stored password through the existing anonymous
/// secret pipe. It is never placed in environment variables or argv.
/// SFTP multiplexes over the tunnel's ControlMaster, which has already
/// authenticated, so SFTP never needs the password at all.
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
}
