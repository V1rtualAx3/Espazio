import EspazioCore
import Foundation

/// Google Chat API with user authentication (https://developers.google.com/workspace/chat/api).
/// Available for Google Workspace accounts whose Cloud project has a configured Chat app;
/// otherwise calls fail and the connector reports "non pris en charge pour ce compte".
public struct GoogleChatService: Sendable {
    static let base = "https://chat.googleapis.com/v1"
    let api: GoogleAPI

    public init(api: GoogleAPI) { self.api = api }

    public struct SpaceActivity: Sendable, Equatable {
        public let space: ChatSpace
        public let lastActive: Date?
    }

    public func listSpaces(limit: Int = 30) async throws -> [SpaceActivity] {
        var components = URLComponents(string: "\(Self.base)/spaces")!
        components.queryItems = [URLQueryItem(name: "pageSize", value: String(min(max(limit, 1), 100)))]
        do {
            let json = try Self.decode(try await api.get(components.url!))
            return Self.parseSpaces(json)
        } catch GoogleAPIError.notFound {
            throw GoogleAPIError.unsupported("Google Chat n’est pas disponible pour ce compte ou ce projet Cloud.")
        }
    }

    /// Most recent messages (oldest first), only those created after `after` when given.
    public func listMessages(spaceID: String, after: Date? = nil, limit: Int = 15) async throws -> [ChatMessage] {
        var components = URLComponents(string: "\(Self.base)/\(spaceID)/messages")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: String(min(max(limit, 1), 50))),
            URLQueryItem(name: "orderBy", value: "createTime desc"),
        ]
        if let after {
            components.queryItems?.append(URLQueryItem(name: "filter", value: "createTime > \"\(Self.formatDate(after))\""))
        }
        let json = try Self.decode(try await api.get(components.url!))
        return Self.parseMessages(json, spaceID: spaceID).reversed()
    }

    /// The user's notification preference for a space, as set in Google Chat.
    public struct NotificationSetting: Sendable, Equatable {
        public enum Level: String, Sendable {
            case all = "ALL"
            case mainConversations = "MAIN_CONVERSATIONS"
            case forYou = "FOR_YOU"
            case off = "OFF"
            case unknown
        }

        public var muted: Bool
        public var level: Level

        public init(muted: Bool, level: Level) {
            self.muted = muted
            self.level = level
        }

        public static let `default` = NotificationSetting(muted: false, level: .unknown)
        /// Muted or notifications off: Espazio ignores the conversation.
        public var isSilenced: Bool { muted || level == .off }
        /// "For you" only: listed, but no pop-up (mentions cannot be told apart reliably).
        public var notifies: Bool { !isSilenced && level != .forYou }
    }

    /// Requires `chat.users.spacesettings`.
    public func notificationSetting(spaceID: String) async throws -> NotificationSetting {
        let url = URL(string: "\(Self.base)/users/me/\(spaceID)/spaceNotificationSetting")!
        return Self.parseNotificationSetting(try Self.decode(try await api.get(url)))
    }

    static func parseNotificationSetting(_ json: JSONValue) -> NotificationSetting {
        NotificationSetting(
            muted: json["muteSetting"]?.stringValue == "MUTED",
            level: json["notificationSetting"]?.stringValue.flatMap(NotificationSetting.Level.init(rawValue:)) ?? .unknown)
    }

    /// When the user last read the space (in any Chat client); `nil` if never.
    /// Requires `chat.users.readstate.readonly`.
    public func lastReadTime(spaceID: String) async throws -> Date? {
        let json = try Self.decode(try await api.get(URL(string: "\(Self.base)/users/me/\(spaceID)/spaceReadState")!))
        return Self.parseDate(json["lastReadTime"]?.stringValue)
    }

    public static func webURL(spaceID: String) -> URL {
        let id = spaceID.replacingOccurrences(of: "spaces/", with: "")
        return URL(string: "https://mail.google.com/chat/u/0/#chat/space/\(id)")!
    }

    static func parseSpaces(_ json: JSONValue) -> [SpaceActivity] {
        var result: [SpaceActivity] = []
        for space in json["spaces"]?.arrayValue ?? [] {
            guard let name = space["name"]?.stringValue else { continue }
            let type = space["spaceType"]?.stringValue ?? space["type"]?.stringValue
            let isDM = type == "DIRECT_MESSAGE" || type == "DM"
            let display = space["displayName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? (isDM ? "Message direct" : "Espace")
            let lastActive = parseDate(space["lastActiveTime"]?.stringValue)
            result.append(SpaceActivity(
                space: ChatSpace(id: name, displayName: display, isDirectMessage: isDM, lastActive: lastActive),
                lastActive: lastActive))
        }
        return result
    }

    static func parseMessages(_ json: JSONValue, spaceID: String) -> [ChatMessage] {
        (json["messages"]?.arrayValue ?? []).compactMap { parseMessage($0, spaceID: spaceID) }
    }

    static func parseMessage(_ json: JSONValue, spaceID: String) -> ChatMessage? {
        guard let name = json["name"]?.stringValue else { return nil }
        let sender = json["sender"]?["displayName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Participant"
        return ChatMessage(
            id: name, spaceID: spaceID, sender: sender, senderID: json["sender"]?["name"]?.stringValue,
            text: json["text"]?.stringValue ?? json["formattedText"]?.stringValue ?? "",
            createTime: parseDate(json["createTime"]?.stringValue), threadName: json["thread"]?["name"]?.stringValue)
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        // Chat returns up to nanosecond precision; trim to milliseconds.
        if let dot = text.firstIndex(of: "."), let z = text.lastIndex(where: { $0 == "Z" || $0 == "+" }), dot < z {
            let fraction = text[text.index(after: dot)..<z].prefix(3)
            if let date = withFraction.date(from: String(text[..<dot]) + "." + fraction + String(text[z...])) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decode(_ data: Data) throws -> JSONValue {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw GoogleAPIError.invalidResponse }
        return json
    }
}

/// People API, only to name the senders of Chat messages (`users/123` → "Alice Martin").
/// Free; requires the People API enabled in the Cloud project and `directory.readonly`.
public struct GooglePeopleService: Sendable {
    let api: GoogleAPI

    public init(api: GoogleAPI) { self.api = api }

    /// Display names keyed by Chat user resource name (`users/123`). Unknown IDs are omitted.
    public func displayNames(forChatUsers userIDs: [String]) async throws -> [String: String] {
        let ids = Array(Set(userIDs.filter { $0.hasPrefix("users/") })).sorted().prefix(50)
        guard !ids.isEmpty else { return [:] }
        var components = URLComponents(string: "https://people.googleapis.com/v1/people:batchGet")!
        components.queryItems = ids.map { URLQueryItem(name: "resourceNames", value: "people/" + $0.dropFirst("users/".count)) }
            + [URLQueryItem(name: "personFields", value: "names")]
        return Self.parseNames(try GoogleChatService.decode(try await api.get(components.url!)))
    }

    static func parseNames(_ json: JSONValue) -> [String: String] {
        var names: [String: String] = [:]
        for response in json["responses"]?.arrayValue ?? [] {
            guard let requested = response["requestedResourceName"]?.stringValue, requested.hasPrefix("people/"),
                  let name = response["person"]?["names"]?.arrayValue?.first?["displayName"]?.stringValue, !name.isEmpty
            else { continue }
            names["users/" + requested.dropFirst("people/".count)] = name
        }
        return names
    }
}

/// Google Calendar API — used only when the account is not synced in macOS Calendar
/// (results are de-duplicated against EventKit by the caller).
public struct GoogleCalendarService: Sendable {
    let api: GoogleAPI

    public init(api: GoogleAPI) { self.api = api }

    public func upcomingEvents(from start: Date, to end: Date, limit: Int = 25) async throws -> [CalendarEvent] {
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(limit)),
        ]
        let data = try await api.get(components.url!)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw GoogleAPIError.invalidResponse }
        return Self.parseEvents(json)
    }

    static func parseEvents(_ json: JSONValue) -> [CalendarEvent] {
        let dateTime = ISO8601DateFormatter()
        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.dateFormat = "yyyy-MM-dd"
        func parse(_ value: JSONValue?) -> (Date, Bool)? {
            if let text = value?["dateTime"]?.stringValue, let date = dateTime.date(from: text) { return (date, false) }
            if let text = value?["date"]?.stringValue, let date = dateOnly.date(from: text) { return (date, true) }
            return nil
        }
        return (json["items"]?.arrayValue ?? []).compactMap { item in
            guard item["status"]?.stringValue != "cancelled",
                let id = item["id"]?.stringValue, let (start, allDay) = parse(item["start"]), let (end, _) = parse(item["end"])
            else { return nil }
            let meet = item["hangoutLink"]?.stringValue
            return CalendarEvent(
                id: id, title: item["summary"]?.stringValue ?? "Sans titre", start: start, end: end, isAllDay: allDay,
                location: item["location"]?.stringValue ?? meet, notes: item["description"]?.stringValue.map { String($0.prefix(2000)) },
                url: meet.flatMap(URL.init(string:)), calendarName: "Google", source: .google,
                iCalUID: item["iCalUID"]?.stringValue, availability: availability(of: item))
        }
    }

    /// Out of office → unavailable; "Disponible" (transparent), working location or an invitation
    /// the user declined → free; otherwise busy (Google's default).
    static func availability(of item: JSONValue) -> EventAvailability {
        switch item["eventType"]?.stringValue {
        case "outOfOffice": return .unavailable
        case "workingLocation": return .free
        default: break
        }
        let me = item["attendees"]?.arrayValue?.first { $0["self"]?.boolValue == true }
        switch me?["responseStatus"]?.stringValue {
        case "declined": return .free
        case "tentative": return .tentative
        default: break
        }
        return item["transparency"]?.stringValue == "transparent" ? .free : .busy
    }
}
