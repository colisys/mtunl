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

    public init(
        id: UUID, name: String, state: TunnelState, pid: Int32? = nil, message: String? = nil,
        restarts: Int = 0, retryIn: Int? = nil, log: [String] = []
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.pid = pid
        self.message = message
        self.restarts = restarts
        self.retryIn = retryIn
        self.log = log
    }
}

public struct ControlRequest: Codable, Sendable {
    /// ping, status, start, stop, restart, startAll, stopAll, reload, shutdown
    public var command: String
    /// A tunnel UUID or a unique name.
    public var target: String?

    public init(command: String, target: String? = nil) {
        self.command = command
        self.target = target
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
