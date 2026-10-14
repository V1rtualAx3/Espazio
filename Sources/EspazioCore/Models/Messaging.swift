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
    /// Last message or event in the space.
    public var lastActive: Date?

    public init(id: String, displayName: String, isDirectMessage: Bool, lastActive: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.isDirectMessage = isDirectMessage
        self.lastActive = lastActive
    }
}

public struct ChatMessage: Sendable, Equatable, Identifiable, Codable {
    /// Resource name, e.g. `spaces/AAAA/messages/BBBB`.
    public let id: String
    public var spaceID: String
    public var sender: String
    /// Sender resource name, e.g. `users/123` (the API gives no display name to user-auth apps).
    public var senderID: String?
    public var text: String
    public var createTime: Date?
    public var threadName: String?

    public init(id: String, spaceID: String, sender: String, senderID: String? = nil, text: String, createTime: Date?, threadName: String?) {
        self.id = id
        self.spaceID = spaceID
        self.sender = sender
        self.senderID = senderID
        self.text = text
        self.createTime = createTime
        self.threadName = threadName
    }
}

/// A Google Chat conversation with messages the user has not read yet.
public struct ChatUnread: Sendable, Equatable, Identifiable {
    public var space: ChatSpace
    /// Unread messages, oldest first (bounded).
    public var messages: [ChatMessage]

    public init(space: ChatSpace, messages: [ChatMessage]) {
        self.space = space
        self.messages = messages
    }

    public var id: String { space.id }
    public var last: ChatMessage? { messages.last }
    public var date: Date? { last?.createTime ?? space.lastActive }

    /// The sender for a direct message, the space name otherwise.
    public var title: String {
        space.isDirectMessage ? (last?.sender ?? space.displayName) : space.displayName
    }

    /// Last message, prefixed by its sender in group spaces.
    public var preview: String {
        guard let last else { return "" }
        return space.isDirectMessage ? last.text : "\(last.sender) : \(last.text)"
    }
}
