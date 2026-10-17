import Foundation

/// An executable plus its argument vector. It is run directly (never through a
/// shell); `shellString` exists only so the user can copy it into a terminal.
public struct ToolCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public var shellString: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    static func quote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_~")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum CommandBuilderError: LocalizedError, Equatable {
    case toolNotFound(String)
    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): return "找不到 \(name)，请先安装（如 brew install \(name)）"
        }
    }
}

public enum CommandBuilder {
    public static let sshPath = "/usr/bin/ssh"

    /// Looks for `socat` in the usual Homebrew/MacPorts locations, then PATH.
    public static func locate(_ tool: String, environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        directories += (environmentPath ?? "").split(separator: ":").map(String.init)
        for directory in directories where directory.hasPrefix("/") {
            let candidate = directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `ssh` needs IPv6 literals in brackets inside a forward specification.
    static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// Builds the command for a config. Call `validate()` first.
    /// Reads `config.sshLoginPassword` for password authentication (requires sshpass).
    public static func command(for config: TunnelConfig, socatPath: String? = nil) throws -> ToolCommand {
        if config.kind == .relay {
            guard let socat = socatPath ?? locate("socat") else { throw CommandBuilderError.toolNotFound("socat") }
            let listen = "TCP-LISTEN:\(config.listenPort),bind=\(config.bindAddress),reuseaddr,fork"
            return ToolCommand(executable: socat, arguments: [listen, "TCP:\(config.targetHost):\(config.targetPort)"])
        }

        // No ControlMaster/ControlPath: a shared connection would make `-N`
        // exit immediately while the forward lives in another process.
        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        // BatchMode is incompatible with password auth and first-time host key acceptance
        if config.sshLoginPassword == nil {
            args += ["-o", "BatchMode=yes"]
        }
        if let port = config.sshPort { args += ["-p", String(port)] }
        if let identity = config.identityFile, !identity.isEmpty {
            args += ["-i", identity, "-o", "IdentitiesOnly=yes"]
        }
        if let jump = config.jumpHost, !jump.isEmpty { args += ["-J", jump] }

        let bind = bracketed(config.bindAddress)
        switch config.kind {
        case .local:
            args += ["-L", "\(bind):\(config.listenPort):\(bracketed(config.targetHost)):\(config.targetPort)"]
        case .remote:
            args += ["-R", "\(bind):\(config.listenPort):\(bracketed(config.targetHost)):\(config.targetPort)"]
        case .dynamic:
            args += ["-D", "\(bind):\(config.listenPort)"]
        case .relay:
            break
        }
        // `--` stops option parsing so a destination can never be read as a flag.
        args += ["--", config.destination]
        
        // Wrap with sshpass if password is provided
        if let password = config.sshLoginPassword {
            guard let sshpass = locate("sshpass") else {
                throw CommandBuilderError.toolNotFound("sshpass")
            }
            return ToolCommand(executable: sshpass, arguments: ["-p", password, sshPath] + args)
        }
        return ToolCommand(executable: sshPath, arguments: args)
    }
}
