import Foundation

/// The final SSH destination the bridge observed in `ssh -v` output (`MTUNL_TARGET user host port`).
struct SSHTarget: Equatable {
    let user: String
    let host: String
    let port: String

    init?(event line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "MTUNL_TARGET", !parts[1].isEmpty, !parts[2].isEmpty,
              let port = Int(parts[3]), (1...65535).contains(port) else { return nil }
        user = String(parts[1])
        host = String(parts[2])
        self.port = String(port)
    }
}

/// Keeps each desired tunnel running: launches the command, watches it, and
/// retries with backoff. All mutable state lives on `queue`.
public final class TunnelSupervisor: @unchecked Sendable {
    public typealias CommandResolver = @Sendable (TunnelConfig) throws -> ToolCommand

    final class Entry {
        var config: TunnelConfig
        var process: Process?
        var errorPipe: Pipe?
        var generation = 0
        var desired = false
        var stopping = false
        var relaunchNow = false
        var pendingRemoval = false
        var state: TunnelState = .stopped
        var message: String?
        var attempts = 0
        var restarts = 0
        var startedAt: Date?
        var retryAt: Date?
        var log: [String] = []
        var retryTimer: DispatchSourceTimer?
        var runningTimer: DispatchSourceTimer?
        var oneTimePassword: String? // temporary password for this session only
        var sshTarget: SSHTarget? // identity the bridge last saw; binds any password to that target
        var passwordRequestID: UUID?
        var usesBridge = false
        var eventBuffer = Data()
        init(config: TunnelConfig) { self.config = config }
    }

    let queue = DispatchQueue(label: "mtunl.supervisor")
    var entries: [UUID: Entry] = [:]
    var order: [UUID] = []
    let resolver: CommandResolver?
    let bridgePath: String
    let backoff: Backoff
    let portInUse: @Sendable (String, Int) -> Bool
    let stableAfter: TimeInterval

    public init(
        backoff: Backoff = Backoff(),
        stableAfter: TimeInterval = 2,
        portInUse: @escaping @Sendable (String, Int) -> Bool = { PortProbe.isInUse(address: $0, port: $1) },
        bridgePath: String = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("mtunl-ssh-bridge").path,
        resolver: CommandResolver? = nil
    ) {
        self.backoff = backoff
        self.stableAfter = stableAfter
        self.portInUse = portInUse
        self.resolver = resolver
        self.bridgePath = bridgePath
    }

    // MARK: Public API

    /// Replaces the known tunnels. Changed tunnels that should be running are
    /// restarted; removed ones are stopped and dropped once they exit.
    public func apply(_ configs: [TunnelConfig]) {
        queue.sync {
            let newIDs = Set(configs.map(\.id))
            for (id, entry) in entries where !newIDs.contains(id) {
                entry.pendingRemoval = true
                stopLocked(entry)
                if entry.process == nil { entries[id] = nil }
            }
            for config in configs {
                if let entry = entries[config.id] {
                    entry.pendingRemoval = false
                    guard entry.config != config else { continue }
                    // Never carry a credential across destination/config changes.
                    entry.oneTimePassword = nil
                    entry.passwordRequestID = nil
                    entry.sshTarget = nil
                    entry.config = config
                    if entry.desired { restartLocked(entry) }
                } else {
                    entries[config.id] = Entry(config: config)
                }
            }
            order = configs.map(\.id)
        }
    }

    public func startAutoStart() {
        queue.sync { for entry in orderedEntries where entry.config.autoStart { startLocked(entry) } }
    }

    public func start(_ id: UUID) { queue.sync { entries[id].map(startLocked) } }
    public func start(_ id: UUID, oneTimePassword: String?) {
        queue.sync {
            if let entry = entries[id], !entry.desired {
                entry.oneTimePassword = entry.config.kind.usesSSH ? oneTimePassword : nil
                startLocked(entry)
            }
        }
    }
    /// Reject stale UI responses after stop, deletion, configuration edits or another start.
    public func supplyPassword(_ id: UUID, requestID: UUID?, password: String?) -> Bool {
        queue.sync {
            guard let entry = entries[id], let requestID,
                  entry.passwordRequestID == requestID,
                  let password, !password.isEmpty else { return false }
            entry.oneTimePassword = password
            startLocked(entry)
            return true
        }
    }

    public func stop(_ id: UUID) { queue.sync { entries[id].map(stopLocked) } }
    public func restart(_ id: UUID) { queue.sync { entries[id].map(restartLocked) } }
    public func startAll() { queue.sync { orderedEntries.forEach(startLocked) } }
    public func stopAll() { queue.sync { orderedEntries.forEach(stopLocked) } }

    public func statuses() -> [TunnelStatus] {
        queue.sync {
            orderedEntries.map { entry in
                let retryIn = entry.retryAt.map { max(0, Int(ceil($0.timeIntervalSinceNow))) }
                return TunnelStatus(
                    id: entry.config.id, name: entry.config.name, state: entry.state,
                    pid: entry.process.map { $0.processIdentifier }, message: entry.message,
                    restarts: entry.restarts, retryIn: entry.state == .waiting ? retryIn : nil,
                    log: entry.log, passwordRequestID: entry.passwordRequestID
                )
            }
        }
    }

    /// Stops everything and waits (up to `timeout`) for the children to exit.
    public func shutdown(timeout: TimeInterval = 5) {
        queue.sync { entries.values.forEach(stopLocked) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.sync(execute: { entries.values.allSatisfy { $0.process == nil } }) { return }
            usleep(50_000)
        }
    }

    var orderedEntries: [Entry] { order.compactMap { entries[$0] } }
}
