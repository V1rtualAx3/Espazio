import Foundation

/// Result of posting an activity, telling the UI what (if anything) should animate.
public enum ActivityPostOutcome: Sendable, Equatable {
    /// The item became the top item and may peek.
    case presented
    /// The item replaced an item with the same coalescing key. `visibleChange` tells whether the
    /// currently displayed content changed (update in place, no new entrance animation).
    case coalesced(visibleChange: Bool)
    /// Accepted but not allowed to interrupt (focus policy or a more important item is shown).
    case queued
    /// Identical to the existing item: nothing to do.
    case duplicate
    /// Rejected by user preferences (muted source).
    case muted
}

/// Pure, deterministic priority queue for notch activities.
///
/// - Ordering: priority first (P0 before P4), then most recent first.
/// - Coalescing: one item per `coalescingKey`.
/// - Expiry: driven by `nextExpiry` so the owner can schedule *one* timer instead of polling.
/// - Bounded: at most `capacity` items; the least important, oldest items are evicted first,
///   and items requiring a decision are never evicted.
public struct ActivityRouter: Sendable {
    public private(set) var items: [ActivityItem] = []
    public var policy: FocusPolicy
    public let capacity: Int

    public init(policy: FocusPolicy = .init(), capacity: Int = 64) {
        precondition(capacity > 0)
        self.policy = policy
        self.capacity = capacity
    }

    /// Highest-priority item currently held.
    public var top: ActivityItem? { items.first }

    /// The item that may be displayed as a peek, honoring the focus policy.
    public var peekCandidate: ActivityItem? {
        items.first(where: { policy.mayPeek($0) })
    }

    /// Number of pending items requiring a decision (shown as a badge in silent mode).
    public var pendingDecisionCount: Int { items.lazy.filter(\.requiresDecision).count }

    /// Earliest expiry among held items.
    public var nextExpiry: Date? { items.compactMap(\.expiresAt).min() }

    @discardableResult
    public mutating func post(_ item: ActivityItem, now: Date) -> ActivityPostOutcome {
        guard policy.accepts(item) else { return .muted }
        if let expiry = item.expiresAt, expiry <= now { return .duplicate }

        let previousPeek = peekCandidate
        if let index = items.firstIndex(where: { $0.coalescingKey == item.coalescingKey }) {
            if items[index].hasSameContent(as: item) {
                // Refresh the lifetime only.
                items[index].expiresAt = item.expiresAt
                return .duplicate
            }
            var replacement = item
            // Keep the identity so SwiftUI updates in place instead of re-inserting.
            replacement = ActivityItem(
                id: items[index].id, source: item.source, priority: item.priority,
                coalescingKey: item.coalescingKey, title: item.title, subtitle: item.subtitle,
                symbol: item.symbol, progress: item.progress, reference: item.reference,
                createdAt: item.createdAt, expiresAt: item.expiresAt, requiresDecision: item.requiresDecision)
            items.remove(at: index)
            insertSorted(replacement)
            let visibleChange = previousPeek?.id == replacement.id || peekCandidate?.id == replacement.id
            return .coalesced(visibleChange: visibleChange)
        }

        insertSorted(item)
        enforceCapacity()
        guard items.contains(where: { $0.id == item.id }) else { return .queued }
        return peekCandidate?.id == item.id ? .presented : .queued
    }

    @discardableResult
    public mutating func dismiss(id: UUID) -> ActivityItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    public mutating func dismiss(coalescingKey: String) -> ActivityItem? {
        guard let index = items.firstIndex(where: { $0.coalescingKey == coalescingKey }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func dismissAll(from source: ActivitySource) {
        items.removeAll { $0.source == source && !$0.requiresDecision }
    }

    /// Removes expired items and returns them.
    @discardableResult
    public mutating func expire(now: Date) -> [ActivityItem] {
        let expired = items.filter { item in item.expiresAt.map { $0 <= now } ?? false }
        if !expired.isEmpty {
            items.removeAll { item in item.expiresAt.map { $0 <= now } ?? false }
        }
        return expired
    }

    // MARK: - Private

    private mutating func insertSorted(_ item: ActivityItem) {
        let index = items.firstIndex(where: { Self.ordered(item, before: $0) }) ?? items.endIndex
        items.insert(item, at: index)
    }

    private static func ordered(_ lhs: ActivityItem, before rhs: ActivityItem) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.createdAt >= rhs.createdAt
    }

    private mutating func enforceCapacity() {
        while items.count > capacity {
            // Items are sorted most-important first, so scan from the end.
            guard let victim = items.lastIndex(where: { !$0.requiresDecision }) else { return }
            items.remove(at: victim)
        }
    }
}
