import Foundation

/// Small LRU cache bounded by entry count and total cost (e.g. bytes of thumbnails).
/// Not thread-safe by itself: own it from a single actor.
public struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var stamp: UInt64
    }

    public let countLimit: Int
    public let costLimit: Int
    private var storage: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var totalCost = 0

    public init(countLimit: Int, costLimit: Int = .max) {
        precondition(countLimit > 0 && costLimit > 0)
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    public var count: Int { storage.count }

    public mutating func value(for key: Key) -> Value? {
        guard var entry = storage[key] else { return nil }
        clock &+= 1
        entry.stamp = clock
        storage[key] = entry
        return entry.value
    }

    /// Inserts a value. Items larger than `costLimit` are not cached.
    public mutating func insert(_ value: Value, for key: Key, cost: Int = 1) {
        guard cost <= costLimit else { return }
        if let old = storage[key] { totalCost -= old.cost }
        clock &+= 1
        storage[key] = Entry(value: value, cost: cost, stamp: clock)
        totalCost += cost
        evictIfNeeded()
    }

    @discardableResult
    public mutating func removeValue(for key: Key) -> Value? {
        guard let entry = storage.removeValue(forKey: key) else { return nil }
        totalCost -= entry.cost
        return entry.value
    }

    public mutating func removeAll() {
        storage.removeAll()
        totalCost = 0
    }

    private mutating func evictIfNeeded() {
        while storage.count > countLimit || totalCost > costLimit {
            guard let oldest = storage.min(by: { $0.value.stamp < $1.value.stamp }) else { return }
            storage[oldest.key] = nil
            totalCost -= oldest.value.cost
        }
    }
}

extension BoundedCache: Sendable where Key: Sendable, Value: Sendable {}
