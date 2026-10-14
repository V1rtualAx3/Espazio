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

    public func listMessages(spaceID: String, limit: Int = 15) async throws -> [ChatMessage] {
        var components = URLComponents(string: "\(Self.base)/\(spaceID)/messages")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: String(min(max(limit, 1), 50))),
            URLQueryItem(name: "orderBy", value: "createTime desc"),
        ]
        let json = try Self.decode(try await api.get(components.url!))
        return Self.parseMessages(json, spaceID: spaceID).reversed()
    }

    /// Requires `chat.messages.create`.
    public func send(spaceID: String, text: String) async throws -> ChatMessage {
        let trimmed = String(text.prefix(4000))
        let data = try await api.post(URL(string: "\(Self.base)/\(spaceID)/messages")!, json: .object(["text": .string(trimmed)]))
        guard let message = Self.parseMessage(try Self.decode(data), spaceID: spaceID) else { throw GoogleAPIError.invalidResponse }
        return message
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
            id: name, spaceID: spaceID, sender: sender,
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

    private static func decode(_ data: Data) throws -> JSONValue {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw GoogleAPIError.invalidResponse }
        return json
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
                iCalUID: item["iCalUID"]?.stringValue)
        }
    }
}
