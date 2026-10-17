import Foundation

/// Persists tunnel definitions as JSON. Holds no secrets: identity files are
/// stored as paths only.
public struct ConfigStore: Sendable {
    public struct Document: Codable, Sendable {
        public var version: Int
        public var tunnels: [TunnelConfig]
    }

    public let url: URL

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MTunl/tunnels.json")
    }

    /// A missing file means "no tunnels yet". A corrupt file throws instead of
    /// being silently replaced, so a bad edit never wipes the user's setup.
    public func load() throws -> [TunnelConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Document.self, from: data).tunnels
    }

    public func save(_ tunnels: [TunnelConfig]) throws {
        try TunnelConfig.validate(all: tunnels)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, tunnels: tunnels))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
