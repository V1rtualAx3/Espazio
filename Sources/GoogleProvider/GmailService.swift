import EspazioCore
import Foundation

/// Gmail API v1 (https://developers.google.com/workspace/gmail/api).
public struct GmailService: Sendable {
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    let api: GoogleAPI

    public init(api: GoogleAPI) { self.api = api }

    public struct Profile: Sendable, Equatable {
        public let email: String
        public let historyID: String
    }

    public func profile() async throws -> Profile {
        let json = try decode(try await api.get(URL(string: "\(Self.base)/profile")!))
        guard let email = json["emailAddress"]?.stringValue, let history = Self.historyID(json["historyId"]) else {
            throw GoogleAPIError.invalidResponse
        }
        return Profile(email: email, historyID: history)
    }

    public func unreadInboxCount() async throws -> Int {
        let json = try decode(try await api.get(URL(string: "\(Self.base)/labels/INBOX")!))
        guard let count = json["messagesUnread"]?.doubleValue else { throw GoogleAPIError.invalidResponse }
        return Int(count)
    }

    /// Latest unread inbox messages with metadata only (no body is downloaded).
    public func unreadMessages(limit: Int) async throws -> [MailSummary] {
        var components = URLComponents(string: "\(Self.base)/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "is:unread in:inbox"),
            URLQueryItem(name: "maxResults", value: String(min(max(limit, 1), 20))),
        ]
        let list = try decode(try await api.get(components.url!))
        let ids = (list["messages"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        var result: [MailSummary] = []
        for id in ids {
            if let summary = try? await message(id: id) { result.append(summary) }
        }
        return result
    }

    public func message(id: String) async throws -> MailSummary {
        var components = URLComponents(string: "\(Self.base)/messages/\(Self.escape(id))")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
        ]
        return try Self.parseMessage(decode(try await api.get(components.url!)))
    }

    /// Returns whether the mailbox changed since `historyID` (one cheap call per sync).
    /// A 404 means the history id is too old: treat as changed.
    public func hasChanges(since historyID: String) async throws -> (changed: Bool, latestHistoryID: String?) {
        var components = URLComponents(string: "\(Self.base)/history")!
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: historyID),
            URLQueryItem(name: "labelId", value: "INBOX"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        do {
            let json = try decode(try await api.get(components.url!))
            let changed = !(json["history"]?.arrayValue ?? []).isEmpty
            return (changed, Self.historyID(json["historyId"]))
        } catch GoogleAPIError.notFound {
            return (true, nil)
        }
    }

    /// Requires `gmail.modify`.
    public func markRead(id: String) async throws {
        _ = try await api.post(
            URL(string: "\(Self.base)/messages/\(Self.escape(id))/modify")!,
            json: .object(["removeLabelIds": .array([.string("UNREAD")])]))
    }

    /// Requires `gmail.modify`. Archiving = removing the INBOX label.
    public func archive(id: String) async throws {
        _ = try await api.post(
            URL(string: "\(Self.base)/messages/\(Self.escape(id))/modify")!,
            json: .object(["removeLabelIds": .array([.string("INBOX")])]))
    }

    public static func webURL(threadID: String) -> URL {
        URL(string: "https://mail.google.com/mail/u/0/#inbox/\(escape(threadID))")!
    }

    // MARK: - Parsing

    static func parseMessage(_ json: JSONValue) throws -> MailSummary {
        guard let id = json["id"]?.stringValue else { throw GoogleAPIError.invalidResponse }
        var headers: [String: String] = [:]
        for header in json["payload"]?["headers"]?.arrayValue ?? [] {
            if let name = header["name"]?.stringValue?.lowercased(), let value = header["value"]?.stringValue {
                headers[name] = value
            }
        }
        let internalDate = json["internalDate"]?.stringValue.flatMap(Double.init)
        let labels = (json["labelIds"]?.arrayValue ?? []).compactMap(\.stringValue)
        return MailSummary(
            id: id, threadID: json["threadId"]?.stringValue ?? id, from: headers["from"] ?? "",
            subject: headers["subject"] ?? "", snippet: decodeEntities(json["snippet"]?.stringValue ?? ""),
            date: internalDate.map { Date(timeIntervalSince1970: $0 / 1000) }, isUnread: labels.contains("UNREAD"))
    }

    /// Gmail snippets are HTML-escaped.
    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    static func historyID(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        if let number = value?.doubleValue { return String(Int64(number)) }
        return nil
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    private func decode(_ data: Data) throws -> JSONValue {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw GoogleAPIError.invalidResponse }
        return json
    }
}

/// Incremental Gmail synchronization: one `history` call when nothing changed, a bounded
/// refresh otherwise. Reports newly arrived message ids for P2 notifications.
public actor GmailMonitor {
    public struct Snapshot: Sendable, Equatable {
        public var account: String
        public var unreadCount: Int
        public var messages: [MailSummary]
        public var newMessageIDs: [String]
    }

    private let service: GmailService
    private let limit: Int
    private var historyID: String?
    private var last: Snapshot?

    public init(service: GmailService, limit: Int = 8) {
        self.service = service
        self.limit = limit
    }

    public func reset() {
        historyID = nil
        last = nil
    }

    public func sync() async throws -> Snapshot {
        if let historyID, let last {
            let (changed, latest) = try await service.hasChanges(since: historyID)
            if !changed {
                if let latest { self.historyID = latest }
                var unchanged = last
                unchanged.newMessageIDs = []
                return unchanged
            }
        }
        let profile = try await service.profile()
        let count = try await service.unreadInboxCount()
        let messages = try await service.unreadMessages(limit: limit)
        let previousIDs = Set(last?.messages.map(\.id) ?? [])
        let newIDs = last == nil ? [] : messages.map(\.id).filter { !previousIDs.contains($0) }
        let snapshot = Snapshot(account: profile.email, unreadCount: count, messages: messages, newMessageIDs: newIDs)
        historyID = profile.historyID
        last = snapshot
        return snapshot
    }

    /// Local update after a successful modify call, so the UI reacts immediately.
    public func remove(messageID: String) {
        guard var snapshot = last else { return }
        let before = snapshot.messages.count
        snapshot.messages.removeAll { $0.id == messageID }
        if snapshot.messages.count < before { snapshot.unreadCount = max(0, snapshot.unreadCount - 1) }
        last = snapshot
    }
}
