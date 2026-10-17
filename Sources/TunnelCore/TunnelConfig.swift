import Foundation

/// A saved tunnel definition. Only the *path* of an identity file is stored;
/// no passwords or key material ever touch this model.
public struct TunnelConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TunnelKind
    /// ssh destination: a host name, address or `~/.ssh/config` alias. Unused for relay.
    public var host: String
    public var user: String?
    public var sshPort: Int?
    public var identityFile: String?
    public var jumpHost: String?
    /// Address the listening side binds to (local for -L/-D/relay, remote for -R).
    public var bindAddress: String
    public var listenPort: Int
    /// Where connections are delivered. Unused for dynamic.
    public var targetHost: String
    public var targetPort: Int
    public var autoStart: Bool

    public static let loopback = "127.0.0.1"

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: TunnelKind = .local,
        host: String = "",
        user: String? = nil,
        sshPort: Int? = nil,
        identityFile: String? = nil,
        jumpHost: String? = nil,
        bindAddress: String = TunnelConfig.loopback,
        listenPort: Int = 0,
        targetHost: String = "localhost",
        targetPort: Int = 0,
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.jumpHost = jumpHost
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
    }

    /// True when the listening side accepts connections from other machines.
    public var exposesToNetwork: Bool {
        !["127.0.0.1", "localhost", "::1"].contains(bindAddress.lowercased())
    }

    public var destination: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    public var summary: String {
        switch kind {
        case .local:
            return "远程 → 本地：\(targetHost):\(targetPort) → \(bindAddress):\(listenPort)（经 \(destination)）"
        case .remote:
            return "本地 → 远程：\(targetHost):\(targetPort) → \(bindAddress):\(listenPort)（经 \(destination)）"
        case .dynamic:
            return "本地 → 远程：SOCKS5 \(bindAddress):\(listenPort)（经 \(destination)）"
        case .relay:
            return "本地 → 目标：\(bindAddress):\(listenPort) → \(targetHost):\(targetPort)"
        }
    }
}
