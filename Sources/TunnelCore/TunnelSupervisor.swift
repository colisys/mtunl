import Foundation

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
        init(config: TunnelConfig) { self.config = config }
    }

    let queue = DispatchQueue(label: "mtunl.supervisor")
    var entries: [UUID: Entry] = [:]
    var order: [UUID] = []
    let resolver: CommandResolver
    let backoff: Backoff
    let portInUse: @Sendable (String, Int) -> Bool
    let stableAfter: TimeInterval

    public init(
        backoff: Backoff = Backoff(),
        stableAfter: TimeInterval = 2,
        portInUse: @escaping @Sendable (String, Int) -> Bool = { PortProbe.isInUse(address: $0, port: $1) },
        resolver: @escaping CommandResolver = { config in
            try config.validate()
            return try CommandBuilder.command(for: config)
        }
    ) {
        self.backoff = backoff
        self.stableAfter = stableAfter
        self.portInUse = portInUse
        self.resolver = resolver
    }

    // MARK: Public API

    /// Replaces the known tunnels. Changed tunnels that should be running are
    /// restarted; removed ones are stopped and dropped once they exit.
    public func apply(_ configs: [TunnelConfig]) {
        queue.sync {
            let newIDs = Set(configs.map(\.id))
            for (id, entry) in entries where !newIDs.contains(id) {
                entry.pendingRemoval = true
                if entry.process == nil { entries[id] = nil } else { stopLocked(entry) }
            }
            for config in configs {
                if let entry = entries[config.id] {
                    entry.pendingRemoval = false
                    guard entry.config != config else { continue }
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
            if let entry = entries[id] {
                entry.oneTimePassword = oneTimePassword
                startLocked(entry)
            }
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
                    log: entry.log
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
