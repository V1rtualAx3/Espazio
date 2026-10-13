import Foundation

/// Connection state of a remote connector, shown in settings and in the expanded notch.
public enum ConnectorStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(account: String?)
    /// The feature is not available for this account (e.g. Google Chat on a personal account).
    case unsupported(reason: String)
    /// Temporary error; the sync loop retries with backoff.
    case error(message: String, retryAt: Date?)
    /// Token revoked / consent missing: user action needed.
    case needsReauthorization
}

public struct MailSummary: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var threadID: String
    public var from: String
    public var subject: String
    public var snippet: String
    public var date: Date?
    public var isUnread: Bool

    public init(id: String, threadID: String, from: String, subject: String, snippet: String, date: Date?, isUnread: Bool) {
        self.id = id
        self.threadID = threadID
        self.from = from
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isUnread = isUnread
    }

    /// Display name part of an RFC 5322 address (`"Jane Doe" <jane@x.com>` → `Jane Doe`).
    public var senderName: String {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.firstIndex(of: "<"), open > trimmed.startIndex {
            let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }
}

public struct ChatSpace: Sendable, Equatable, Identifiable, Codable {
    /// Resource name, e.g. `spaces/AAAA`.
    public let id: String
    public var displayName: String
    public var isDirectMessage: Bool

    public init(id: String, displayName: String, isDirectMessage: Bool) {
        self.id = id
        self.displayName = displayName
        self.isDirectMessage = isDirectMessage
    }
}

public struct ChatMessage: Sendable, Equatable, Identifiable, Codable {
    /// Resource name, e.g. `spaces/AAAA/messages/BBBB`.
    public let id: String
    public var spaceID: String
    public var sender: String
    public var text: String
    public var createTime: Date?
    public var threadName: String?

    public init(id: String, spaceID: String, sender: String, text: String, createTime: Date?, threadName: String?) {
        self.id = id
        self.spaceID = spaceID
        self.sender = sender
        self.text = text
        self.createTime = createTime
        self.threadName = threadName
    }
}
