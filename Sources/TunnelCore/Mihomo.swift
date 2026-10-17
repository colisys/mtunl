import Foundation
import Network

public struct MihomoSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var binaryPath: String
    /// Optional HTTPS prefix prepended to the complete upstream URL (metadata and assets).
    public var mirrorURL: String
    public var dynamicTunnelID: UUID?
    public var cidrs: [String]
    public var mixedPort: Int
    public var controllerPort: Int
    public var autoRoute: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled, binaryPath, mirrorURL, dynamicTunnelID, cidrs, mixedPort, controllerPort, autoRoute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath) ?? ""
        mirrorURL = try container.decodeIfPresent(String.self, forKey: .mirrorURL) ?? ""
        dynamicTunnelID = try container.decodeIfPresent(UUID.self, forKey: .dynamicTunnelID)
        cidrs = try container.decodeIfPresent([String].self, forKey: .cidrs) ?? []
        mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 17890
        controllerPort = try container.decodeIfPresent(Int.self, forKey: .controllerPort) ?? 19090
        autoRoute = try container.decodeIfPresent(Bool.self, forKey: .autoRoute) ?? true
    }

    public init(
        enabled: Bool = false,
        binaryPath: String = "",
        mirrorURL: String = "",
        dynamicTunnelID: UUID? = nil,
        cidrs: [String] = [],
        mixedPort: Int = 17890,
        controllerPort: Int = 19090,
        autoRoute: Bool = true
    ) {
        self.enabled = enabled
        self.binaryPath = binaryPath
        self.mirrorURL = mirrorURL
        self.dynamicTunnelID = dynamicTunnelID
        self.cidrs = cidrs
        self.mixedPort = mixedPort
        self.controllerPort = controllerPort
        self.autoRoute = autoRoute
    }
}

public struct MihomoStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case stopped, starting, running, failed }
    public var state: State
    public var message: String?
    public var pid: Int32?
    public var configPath: String?
    public var log: [String]
    public var actualVersion: String?
    public var versionError: String?
    public var tunEnabled: Bool?
    public var tunError: String?

    public var captureStatusText: String {
        guard state == .running else { return "TUN 未运行" }
        if tunEnabled == true { return "TUN 已启用" }
        if tunEnabled == false { return "TUN 未启用" }
        return "TUN 状态未确认"
    }
    public var cachedKernel: MihomoKernelInfo?
    public var downloadInProgress: Bool?
    public var downloadMessage: String?

    public var downloadButtonTitle: String {
        if downloadInProgress == true { return "检查 / 下载中…" }
        return cachedKernel == nil ? "下载内核" : "更新内核"
    }

    public init(state: State = .stopped, message: String? = nil, pid: Int32? = nil,
                configPath: String? = nil, log: [String] = []) {
        self.state = state
        self.message = message
        self.pid = pid
        self.configPath = configPath
        self.log = log
    }
}

public enum MihomoError: LocalizedError, Equatable {
    case invalid(String)
    case missingBinary(String)
    case tunnelNotFound
    case tunnelMustBeDynamic
    case process(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value): return value
        case .missingBinary(let path): return "找不到可执行的 Mihomo：\(path)"
        case .tunnelNotFound: return "找不到 Mihomo 使用的动态 SSH 隧道"
        case .tunnelMustBeDynamic: return "Mihomo 出口必须选择动态转发（-D）隧道"
        case .process(let value): return value
        }
    }
}

public enum MihomoConfigBuilder {
    public static func validate(_ settings: MihomoSettings, tunnels: [TunnelConfig]) throws -> TunnelConfig {
        if !settings.binaryPath.isEmpty {
            guard settings.binaryPath.hasPrefix("/") else {
                throw MihomoError.invalid("Mihomo 路径必须是绝对路径")
            }
        }
        guard (1024...65535).contains(settings.mixedPort),
              (1024...65535).contains(settings.controllerPort),
              settings.mixedPort != settings.controllerPort else {
            throw MihomoError.invalid("Mihomo 端口必须在 1024–65535 之间且不能相同")
        }
        guard !settings.cidrs.isEmpty else { throw MihomoError.invalid("至少需要一个内网 CIDR 网段") }
        guard settings.cidrs.allSatisfy(validCIDR) else { throw MihomoError.invalid("内网 CIDR 网段格式无效") }
        guard let id = settings.dynamicTunnelID,
              let tunnel = tunnels.first(where: { $0.id == id }) else { throw MihomoError.tunnelNotFound }
        guard tunnel.kind == .dynamic else { throw MihomoError.tunnelMustBeDynamic }
        return tunnel
    }

    public static func yaml(settings: MihomoSettings, socksAddress: String = "127.0.0.1", socksPort: Int) throws -> String {
        guard !settings.cidrs.isEmpty else { throw MihomoError.invalid("至少需要一个内网 CIDR 网段") }
        let rules = settings.cidrs.map { cidr in
            let ruleType = cidr.contains(":") ? "IP-CIDR6" : "IP-CIDR"
            return "  - \(ruleType),\(cidr),MTunl SSH Group,no-resolve"
        }.joined(separator: "\n")
        let autoRoute = settings.autoRoute ? "true" : "false"
        return """
        mixed-port: \(settings.mixedPort)
        allow-lan: false
        mode: rule
        log-level: info
        external-controller: 127.0.0.1:\(settings.controllerPort)
        tun:
          enable: true
          stack: system
          auto-route: \(autoRoute)
          auto-detect-interface: true
        dns:
          enable: true
          enhanced-mode: fake-ip
          listen: 127.0.0.1:0
        proxies:
          - name: MTunl SSH
            type: socks5
            server: \(socksAddress)
            port: \(socksPort)
            udp: false
        proxy-groups:
          - name: MTunl SSH Group
            type: select
            proxies:
              - MTunl SSH
        rules:
        \(rules)
          - MATCH,DIRECT
        """
    }

    private static func validCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        if value.contains(":") {
            return (0...128).contains(prefix) && IPv6Address(String(parts[0])) != nil
        }
        guard (0...32).contains(prefix) else { return false }
        let octets = parts[0].split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { octet in
            guard let number = Int(octet) else { return false }
            return (0...255).contains(number)
        }
    }
}

public struct MihomoConfigStore: Sendable {
    public let url: URL
    public init(url: URL = MihomoConfigStore.defaultURL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MTunl/mihomo.json")
    }
    public func load() throws -> MihomoSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return MihomoSettings() }
        return try JSONDecoder().decode(MihomoSettings.self, from: Data(contentsOf: url))
    }
    public func save(_ settings: MihomoSettings) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
