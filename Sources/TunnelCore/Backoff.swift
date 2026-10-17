import Foundation

/// Exponential reconnect delay: 1, 2, 4, ... capped.
public struct Backoff: Equatable, Sendable {
    public var base: TimeInterval
    public var cap: TimeInterval
    /// A run at least this long counts as healthy and resets the sequence.
    public var healthyUptime: TimeInterval

    public init(base: TimeInterval = 1, cap: TimeInterval = 30, healthyUptime: TimeInterval = 60) {
        self.base = base
        self.cap = cap
        self.healthyUptime = healthyUptime
    }

    /// `attempt` is 1 for the first retry after a failure.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 16)
        return min(cap, base * pow(2, Double(exponent)))
    }
}
