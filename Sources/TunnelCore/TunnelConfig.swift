import Foundation

public enum SSHAuthMethod: String, Codable, Sendable, CaseIterable {
    case password = "密码"
    case privateKey = "密钥"
}

/// A saved tunnel definition. Only the *path* of an identity file is stored;
/// no passwords or key material ever touch this model.

public struct TunnelConfig: Identifiable, Equatable, Sendable {
    
    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, user, sshPort, identityFile, jumpHost
        case bindAddress, listenPort, targetHost, targetPort, autoStart
        case sshAuthMethod
    }
    
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
    /// SSH authentication method: password or private key
    public var sshAuthMethod: SSHAuthMethod


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
        autoStart: Bool = false,
        sshAuthMethod: SSHAuthMethod = .privateKey
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
        self.sshAuthMethod = sshAuthMethod

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

extension TunnelConfig: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(TunnelKind.self, forKey: .kind)
        host = try container.decode(String.self, forKey: .host)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        jumpHost = try container.decodeIfPresent(String.self, forKey: .jumpHost)
        bindAddress = try container.decode(String.self, forKey: .bindAddress)
        listenPort = try container.decode(Int.self, forKey: .listenPort)
        targetHost = try container.decode(String.self, forKey: .targetHost)
        targetPort = try container.decode(Int.self, forKey: .targetPort)
        autoStart = try container.decode(Bool.self, forKey: .autoStart)
        sshAuthMethod = try container.decodeIfPresent(SSHAuthMethod.self, forKey: .sshAuthMethod) ?? .privateKey

    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encodeIfPresent(sshPort, forKey: .sshPort)
        try container.encodeIfPresent(identityFile, forKey: .identityFile)
        try container.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try container.encode(bindAddress, forKey: .bindAddress)
        try container.encode(listenPort, forKey: .listenPort)
        try container.encode(targetHost, forKey: .targetHost)
        try container.encode(targetPort, forKey: .targetPort)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(sshAuthMethod, forKey: .sshAuthMethod)

    }
}
