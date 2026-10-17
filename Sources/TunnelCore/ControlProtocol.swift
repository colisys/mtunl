import Foundation

public enum ControlProtocol {
    // Optional Mihomo status additions are backward compatible; do not force daemon restart.
    public static let version = 2
}

public enum TunnelState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    /// Exited unexpectedly; a retry is scheduled.
    case waiting
    /// Cannot run until the user fixes something (config error, missing tool).
    case failed
}

public struct TunnelStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: TunnelState
    public var pid: Int32?
    public var message: String?
    public var restarts: Int
    /// Seconds until the next retry while `waiting`.
    public var retryIn: Int?
    public var log: [String]
    /// Non-secret challenge issued only after actual final-target password fallback evidence.
    public var passwordRequestID: UUID?

    public init(
        id: UUID, name: String, state: TunnelState, pid: Int32? = nil, message: String? = nil,
        restarts: Int = 0, retryIn: Int? = nil, log: [String] = [], passwordRequestID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.pid = pid
        self.message = message
        self.restarts = restarts
        self.retryIn = retryIn
        self.log = log
        self.passwordRequestID = passwordRequestID
    }
}

public struct ControlRequest: Codable, Sendable {
    /// ping, status, start, stop, restart, startAll, stopAll, reload, shutdown
    public var command: String
    /// A tunnel UUID or a unique name.
    public var target: String?
    /// Session-only credential, retained in daemon memory until stop/removal/auth failure.
    /// Password starts use a new command so old daemons cannot fall back to argv transport.
    public var oneTimePassword: String?
    public var passwordRequestID: UUID?

    public init(command: String, target: String? = nil, oneTimePassword: String? = nil, passwordRequestID: UUID? = nil) {
        self.command = command == "start" && oneTimePassword != nil ? "startSession" : command
        self.target = target
        self.oneTimePassword = oneTimePassword
        self.passwordRequestID = passwordRequestID
    }
}

public struct ControlResponse: Codable, Sendable {
    public var protocolVersion: Int?
    public var success: Bool
    public var message: String?
    public var error: String?
    public var statuses: [TunnelStatus]?
    public var mihomo: MihomoStatus?

    public init(success: Bool, message: String? = nil, error: String? = nil,
                statuses: [TunnelStatus]? = nil, mihomo: MihomoStatus? = nil,
                protocolVersion: Int? = ControlProtocol.version) {
        self.protocolVersion = protocolVersion
        self.success = success
        self.message = message
        self.error = error
        self.statuses = statuses
        self.mihomo = mihomo
    }
}

public enum ControlPaths {
    /// Short, per-user path: sun_path is only ~104 bytes on macOS.
    public static var directory: String { "/tmp/mtunl-\(getuid())" }
    public static var socket: String { directory + "/ctl.sock" }
}
