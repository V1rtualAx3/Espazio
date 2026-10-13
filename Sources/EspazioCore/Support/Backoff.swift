import Foundation

/// Exponential backoff with bounded jitter, used by every network sync loop.
public struct ExponentialBackoff: Sendable, Equatable {
    public var base: TimeInterval
    public var maximum: TimeInterval
    /// Jitter ratio in 0...1 applied symmetrically (0.2 = ±20 %).
    public var jitter: Double

    public init(base: TimeInterval = 2, maximum: TimeInterval = 15 * 60, jitter: Double = 0.2) {
        precondition(base > 0 && maximum >= base && (0...1).contains(jitter))
        self.base = base
        self.maximum = maximum
        self.jitter = jitter
    }

    /// Delay before retry number `attempt` (0-based). `random` must return a value in 0...1.
    public func delay(attempt: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 32))
        let raw = min(base * pow(2, exponent), maximum)
        let factor = 1 + jitter * (2 * min(max(random, 0), 1) - 1)
        return min(raw * factor, maximum)
    }
}

/// Token bucket rate limiter (pure; caller supplies time).
public struct TokenBucket: Sendable, Equatable {
    public let capacity: Double
    /// Tokens added per second.
    public let refillRate: Double
    public private(set) var tokens: Double
    public private(set) var lastRefill: Date

    public init(capacity: Double, refillRate: Double, now: Date) {
        precondition(capacity > 0 && refillRate > 0)
        self.capacity = capacity
        self.refillRate = refillRate
        self.tokens = capacity
        self.lastRefill = now
    }

    /// Consumes `cost` tokens if available.
    public mutating func tryConsume(_ cost: Double = 1, now: Date) -> Bool {
        refill(now: now)
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }

    /// Seconds until `cost` tokens are available.
    public mutating func waitTime(for cost: Double = 1, now: Date) -> TimeInterval {
        refill(now: now)
        return tokens >= cost ? 0 : (cost - tokens) / refillRate
    }

    private mutating func refill(now: Date) {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(capacity, tokens + elapsed * refillRate)
        lastRefill = now
    }
}
