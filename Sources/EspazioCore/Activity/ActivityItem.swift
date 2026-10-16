import Foundation

/// Notification priority as defined in the specification (§6). Lower raw value = more important.
public enum ActivityPriority: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Blocking agent permission / question.
    case p0 = 0
    /// Imminent deadline, important system event.
    case p1 = 1
    /// Google Chat, Gmail.
    case p2 = 2
    /// Volume, battery, track change.
    case p3 = 3
    /// Discreet presence of an activity / media.
    case p4 = 4

    /// `a < b` means `a` is *more* important than `b`.
    public static func < (lhs: ActivityPriority, rhs: ActivityPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The module that produced an activity. Used for per-module preferences and routing.
public enum ActivitySource: String, Sendable, Codable, CaseIterable {
    case agents
    case calendar
    case reminders
    case mail
    case chat
    case media
    case volume
    case audioDevice
    case battery
    case power
    case keyboard
    case bluetooth
    case system
}

/// A single item that can be shown in the notch (peek) or kept in the queue.
///
/// Items carry only display-ready, already redacted text. The concrete module state
/// (mail list, sessions, …) lives in the corresponding provider; `reference` lets the UI
/// route an action back to that provider.
public struct ActivityItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var source: ActivitySource
    public var priority: ActivityPriority
    /// Two items with the same key describe the same thing (e.g. "volume", "approval:<id>").
    /// Posting a new item with an existing key replaces the old one without re-animating.
    public var coalescingKey: String
    public var title: String
    public var subtitle: String?
    /// SF Symbol name; rendered monochrome.
    public var symbol: String
    /// Optional 0...1 value (volume, battery).
    public var progress: Double?
    /// Provider-specific identifier (request id, event id, message id…).
    public var reference: String?
    public var createdAt: Date
    /// When the item stops being relevant. `nil` = until dismissed.
    public var expiresAt: Date?
    /// Whether the item is "sticky" (requires a decision) and can never auto-expire.
    public var requiresDecision: Bool

    public init(
        id: UUID = UUID(),
        source: ActivitySource,
        priority: ActivityPriority,
        coalescingKey: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        progress: Double? = nil,
        reference: String? = nil,
        createdAt: Date,
        expiresAt: Date? = nil,
        requiresDecision: Bool = false
    ) {
        self.id = id
        self.source = source
        self.priority = priority
        self.coalescingKey = coalescingKey
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.progress = progress
        self.reference = reference
        self.createdAt = createdAt
        self.expiresAt = requiresDecision ? nil : expiresAt
        self.requiresDecision = requiresDecision
    }

    /// Content equality, ignoring identity and timestamps. Used to suppress duplicate animations.
    public func hasSameContent(as other: ActivityItem) -> Bool {
        source == other.source && priority == other.priority && title == other.title
            && subtitle == other.subtitle && symbol == other.symbol && progress == other.progress
            && reference == other.reference
    }
}
