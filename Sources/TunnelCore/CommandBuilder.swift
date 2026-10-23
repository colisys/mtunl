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

    case invalidSessionPassword
    case unknownSSHTarget
    case noTerminalSession
    public var errorDescription: String? {
        switch self {
        case .invalidSessionPassword: return "会话密码必须为 1–1023 字节 UTF-8，且不含控制字符"
        case .noTerminalSession: return "socat 中继不提供终端会话"

        case .toolNotFound(let name): return "找不到 \(name)，请先安装（如 brew install \(name)）"
        case .unknownSSHTarget: return "尚未确认 SSH 认证目标，拒绝发送密码"
        }
    }
}

public enum CommandBuilder {
    public static let sshPath = "/usr/bin/ssh"

    /// Per-tunnel ControlMaster socket path; the daemon creates the directory at startup.
    public static func sshControlPath(for config: TunnelConfig) -> String {
        "/tmp/mtunl-\(getuid())/ssh-\(config.id.uuidString).sock"
    }

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
    /// Passwords are never part of a command. The supervisor supplies only a capability flag.
    public static func command(for config: TunnelConfig, socatPath: String? = nil, passwordFallback: Bool = false) throws -> ToolCommand {
        if config.kind == .relay {
            guard let socat = socatPath ?? locate("socat") else { throw CommandBuilderError.toolNotFound("socat") }
            let listen = "TCP-LISTEN:\(config.listenPort),bind=\(config.bindAddress),reuseaddr,fork"
            return ToolCommand(executable: socat, arguments: [listen, "TCP:\(config.targetHost):\(config.targetPort)"])
        }

        // The tunnel process is the ControlMaster: terminal sessions multiplex over
        // this socket without re-authenticating. `-N` stays quiet because we are
        // the master, not a client of another connection.
        var args = try sshBaseArguments(for: config)
        args.insert("-N", at: 0)
        if passwordFallback {
            args += ["-o", "NumberOfPasswordPrompts=1",
                     "-o", "PasswordAuthentication=yes", "-o", "PubkeyAuthentication=yes"]
            // Remove the earlier "-o PasswordAuthentication=no" pair (both flag and value).
            if let index = args.firstIndex(of: "PasswordAuthentication=no"), index > 0, args[index - 1] == "-o" {
                args.remove(at: index)
                args.remove(at: index - 1)
            }
        }

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

        return ToolCommand(executable: sshPath, arguments: args)
    }

    /// A plain interactive login shell in a real terminal, multiplexing over the
    /// tunnel's existing SSH connection if running. No forwards, no `-N`: password
    /// and MFA prompts, and the remote shell itself are handled by ssh interactively.
    /// If the tunnel is not running, ssh falls back to a direct (non-multiplexed)
    /// connection with normal auth prompts.
    public static func terminalSession(for config: TunnelConfig) throws -> ToolCommand {
        guard config.kind.usesSSH else { throw CommandBuilderError.noTerminalSession }
        let socketPath = sshControlPath(for: config)
        var args = [
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=ask",
        ]
        args += try connectionArguments(for: config)
        return ToolCommand(executable: sshPath, arguments: args + ["--", config.destination])
    }

    /// Connection options shared by forward-only and interactive sessions.
    /// The forward process runs as ControlMaster so terminal sessions can
    /// multiplex over it; the socket lives in the daemon's private per-user directory.
    private static func sshBaseArguments(for config: TunnelConfig) throws -> [String] {
        var args = [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(sshControlPath(for: config))",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "PreferredAuthentications=publickey,password",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "BatchMode=no",
            "-o", "PasswordAuthentication=no",
        ]
        args += try connectionArguments(for: config)
        return args
    }

    private static func connectionArguments(for config: TunnelConfig) throws -> [String] {
        var args: [String] = []
        if let port = config.sshPort { args += ["-p", String(port)] }
        if let identity = config.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let jump = config.jumpHost, !jump.isEmpty { args += ["-J", jump] }
        return args
    }
}
