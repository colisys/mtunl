import Foundation
import Network

public struct MihomoSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var binaryPath: String
    /// Optional HTTPS prefix prepended to the complete upstream URL (metadata and assets).
    public var mirrorURL: String
    public var dynamicTunnelID: UUID?
    /// Mihomo rule expressions without an outbound; matching traffic uses the selected SSH proxy.
    public var rules: [String]
    public var mixedPort: Int
    public var controllerPort: Int
    public var autoRoute: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled, binaryPath, mirrorURL, dynamicTunnelID, rules, cidrs, mixedPort, controllerPort, autoRoute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath) ?? ""
        mirrorURL = try container.decodeIfPresent(String.self, forKey: .mirrorURL) ?? ""
        dynamicTunnelID = try container.decodeIfPresent(UUID.self, forKey: .dynamicTunnelID)
        if let rules = try container.decodeIfPresent([String].self, forKey: .rules) {
            self.rules = rules
        } else {
            self.rules = (try container.decodeIfPresent([String].self, forKey: .cidrs) ?? []).map {
                "\($0.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\($0),no-resolve"
            }
        }
        mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 17890
        controllerPort = try container.decodeIfPresent(Int.self, forKey: .controllerPort) ?? 19090
        autoRoute = try container.decodeIfPresent(Bool.self, forKey: .autoRoute) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(binaryPath, forKey: .binaryPath)
        try container.encode(mirrorURL, forKey: .mirrorURL)
        try container.encodeIfPresent(dynamicTunnelID, forKey: .dynamicTunnelID)
        try container.encode(rules, forKey: .rules)
        try container.encode(mixedPort, forKey: .mixedPort)
        try container.encode(controllerPort, forKey: .controllerPort)
        try container.encode(autoRoute, forKey: .autoRoute)
    }

    public init(
        enabled: Bool = false,
        binaryPath: String = "",
        mirrorURL: String = "",
        dynamicTunnelID: UUID? = nil,
        rules: [String] = [],
        mixedPort: Int = 17890,
        controllerPort: Int = 19090,
        autoRoute: Bool = true
    ) {
        self.enabled = enabled
        self.binaryPath = binaryPath
        self.mirrorURL = mirrorURL
        self.dynamicTunnelID = dynamicTunnelID
        self.rules = rules
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
        _ = try normalizedRules(settings.rules)
        guard let id = settings.dynamicTunnelID,
              let tunnel = tunnels.first(where: { $0.id == id }) else { throw MihomoError.tunnelNotFound }
        guard tunnel.kind == .dynamic else { throw MihomoError.tunnelMustBeDynamic }
        return tunnel
    }

    public static func yaml(settings: MihomoSettings, socksAddress: String = "127.0.0.1", socksPort: Int) throws -> String {
        let rules = try normalizedRules(settings.rules).map { rule in
            let parts = rule.split(separator: ",", omittingEmptySubsequences: false)
            let noResolve = parts.last?.lowercased() == "no-resolve" && parts.count > 1
            let match = noResolve ? parts.dropLast().joined(separator: ",") : rule
            let value = match + ",MTunl SSH Group" + (noResolve ? ",no-resolve" : "")
            return "  - \(yamlString(value))"
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

    private static func normalizedRules(_ values: [String]) throws -> [String] {
        guard !values.isEmpty, values.count <= 256,
              values.allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw MihomoError.invalid("请填写 1–256 条 Mihomo 规则，每条不超过 4096 字节")
        }
        let rules = values.compactMap(normalizedRule)
        guard rules.count == values.count else {
            throw MihomoError.invalid("规则格式无效：每行填写 Mihomo 匹配规则，不要填写出口策略")
        }
        return rules
    }

    private static func normalizedRule(_ value: String) -> String? {
        let expression = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty,
              !expression.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let comma = expression.firstIndex(of: ",") else {
            return expression.uppercased() == "MATCH" ? "MATCH" : nil
        }
        let type = expression[..<comma].trimmingCharacters(in: .whitespaces)
        let matcher = expression[expression.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        let actions: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYRST", "PASS", "COMPATIBLE", "GLOBAL", "MTUNL SSH GROUP"]
        let fields = matcher.split(separator: ",", omittingEmptySubsequences: false)
        guard let last = fields.last else { return nil }
        let finalField = last.trimmingCharacters(in: .whitespaces).uppercased()
        guard !type.isEmpty, type.utf8.count <= 64,
              type.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                  ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              }),
              type.uppercased() != "MATCH", !matcher.isEmpty, !matcher.hasPrefix(","),
              !matcher.contains(",,"), !matcher.hasSuffix(","),
              !actions.contains(finalField) else { return nil }
        return "\(type.uppercased()),\(matcher)"
    }

    private static func yamlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
