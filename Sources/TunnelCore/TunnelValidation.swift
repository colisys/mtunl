import Foundation

public struct TunnelValidationError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

extension TunnelConfig {
    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:"
    )
    private static let userCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    private static let jumpCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:@,[]"
    )

    /// A value that ssh or socat could mistake for an option, or that carries
    /// control characters, is rejected before it can reach an argument list.
    private static func isPlain(_ value: String, allowed: CharacterSet, maxLength: Int = 253) -> Bool {
        !value.isEmpty && value.count <= maxLength && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func validPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TunnelValidationError("名称不能为空，最长 64 个字符，且不能含控制字符")
        }
        guard Self.validPort(listenPort) else { throw TunnelValidationError("监听端口必须在 1–65535 之间") }
        guard Self.isPlain(bindAddress, allowed: Self.hostCharacters) else {
            throw TunnelValidationError("监听地址无效")
        }
        if kind == .relay, bindAddress.contains(":") {
            throw TunnelValidationError("socat 中继暂不支持 IPv6 地址")
        }
        if kind.needsTarget {
            guard Self.isPlain(targetHost, allowed: Self.hostCharacters) else {
                throw TunnelValidationError("目标主机无效")
            }
            guard Self.validPort(targetPort) else { throw TunnelValidationError("目标端口必须在 1–65535 之间") }
            if kind == .relay, targetHost.contains(":") {
                throw TunnelValidationError("socat 中继暂不支持 IPv6 地址")
            }
        }
        guard kind.usesSSH else { return }
        guard Self.isPlain(host, allowed: Self.hostCharacters) else {
            throw TunnelValidationError("SSH 主机无效（可填 ~/.ssh/config 中的别名）")
        }
        if let user, !user.isEmpty, !Self.isPlain(user, allowed: Self.userCharacters, maxLength: 64) {
            throw TunnelValidationError("SSH 用户名无效")
        }
        if let sshPort, !Self.validPort(sshPort) { throw TunnelValidationError("SSH 端口必须在 1–65535 之间") }
        if let jumpHost, !jumpHost.isEmpty {
            let hops = jumpHost.split(separator: ",", omittingEmptySubsequences: false)
            guard Self.isPlain(jumpHost, allowed: Self.jumpCharacters, maxLength: 512),
                  hops.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
                throw TunnelValidationError("跳板机无效")
            }
        }
        if let identityFile, !identityFile.isEmpty {
            guard identityFile.hasPrefix("/") || identityFile.hasPrefix("~/"),
                  identityFile.count <= 1024,
                  !identityFile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw TunnelValidationError("私钥路径必须是绝对路径或以 ~/ 开头")
            }
        }
    }

    /// Validates a whole set: each entry, plus unique names and unique local listeners.
    public static func validate(all configs: [TunnelConfig]) throws {
        var names = Set<String>()
        var listeners = Set<String>()
        for config in configs {
            try config.validate()
            guard names.insert(config.name.lowercased()).inserted else {
                throw TunnelValidationError("名称重复：\(config.name)")
            }
            if config.kind.listensLocally {
                let key = "\(config.bindAddress.lowercased()):\(config.listenPort)"
                guard listeners.insert(key).inserted else {
                    throw TunnelValidationError("本地监听地址重复：\(key)")
                }
            }
        }
    }
}
