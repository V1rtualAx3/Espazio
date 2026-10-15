import Foundation

public enum CalendarEventSource: String, Sendable, Codable {
    case eventKit
    case google
}

/// How the event shows the user's time ("Afficher comme" in Calendar, "Occupé / Disponible" in Google).
public enum EventAvailability: String, Sendable, Codable {
    case busy
    case free
    case tentative
    /// Out of office ("Absent").
    case unavailable
    /// The calendar does not say: treated as busy.
    case unknown
}

public struct CalendarEvent: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var url: URL?
    public var calendarName: String?
    public var source: CalendarEventSource
    /// iCalendar UID when known (EventKit `calendarItemExternalIdentifier`, Google `iCalUID`).
    public var iCalUID: String?
    public var availability: EventAvailability

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
        notes: String? = nil, url: URL? = nil, calendarName: String? = nil, source: CalendarEventSource,
        iCalUID: String? = nil, availability: EventAvailability = .unknown
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.calendarName = calendarName
        self.source = source
        self.iCalUID = iCalUID
        self.availability = availability
    }

    public var meetingURL: URL? {
        MeetingLinkExtractor.firstMeetingURL(in: [url?.absoluteString, location, notes].compactMap { $0 })
    }

    public func isOngoing(at date: Date) -> Bool { !isAllDay && start <= date && date < end }

    /// Only events showing the user as busy limit interruptions; "free" (a lunch break) and
    /// out-of-office events stay in the agenda without counting as a meeting.
    public var countsAsMeeting: Bool { availability == .busy || availability == .unknown }

    public func isMeeting(at date: Date) -> Bool { countsAsMeeting && isOngoing(at: date) }
}

public extension Array where Element == CalendarEvent {
    /// How long a started event stays the one shown before the next takes its place.
    static var startedEventGrace: TimeInterval { 15 * 60 }

    /// Event to show in the agenda, today only: the earliest timed event not started yet or
    /// started less than 15 min ago (a long meeting does not hide the next one until it ends),
    /// else an all-day event covering today. Tomorrow's events never show.
    func eventToShow(at date: Date, calendar: Calendar = .current) -> CalendarEvent? {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        let timed = filter {
            !$0.isAllDay && $0.start < endOfDay && $0.end > date && date.timeIntervalSince($0.start) < Self.startedEventGrace
        }
        return timed.min { $0.start < $1.start } ?? first { $0.isAllDay && $0.start <= date && $0.end > date }
    }

    /// Next busy, timed event that has not started yet: the one the notch counts down to.
    func nextMeeting(after date: Date) -> CalendarEvent? {
        filter { !$0.isAllDay && $0.countsAsMeeting && $0.start > date }.min { $0.start < $1.start }
    }
}

/// Share of the countdown window still to run before an event starts, from 1 (window just
/// entered) to 0 (start), for the circular hourglass.
public enum CountdownProgress {
    public static func remaining(until start: Date, window: TimeInterval, now: Date) -> Double {
        guard window > 0 else { return 0 }
        return Swift.min(Swift.max(start.timeIntervalSince(now) / window, 0), 1)
    }
}

public enum MeetingLinkExtractor {
    /// Hosts recognized as video meeting providers (suffix match).
    public static let meetingHosts = [
        "meet.google.com", "zoom.us", "zoom.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "facetime.apple.com", "chime.aws", "meet.jit.si", "gotomeeting.com", "around.co",
        "app.slack.com",
    ]

    private static let detector = try? NSRegularExpression(pattern: #"https://[^\s<>"')\]]+"#)

    public static func firstMeetingURL(in texts: [String]) -> URL? {
        for text in texts {
            guard let detector else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                var candidate = String(text[swiftRange])
                while let last = candidate.last, ".,;:".contains(last) { candidate.removeLast() }
                guard let url = URL(string: candidate), let host = url.host?.lowercased() else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }
}

/// Removes Google Calendar events already present through EventKit (macOS-synced accounts).
public enum CalendarDeduplicator {
    public static func merge(eventKit: [CalendarEvent], google: [CalendarEvent]) -> [CalendarEvent] {
        let uids = Set(eventKit.compactMap { $0.iCalUID?.lowercased() })
        let signatures = Set(eventKit.map(signature))
        let extra = google.filter { event in
            if let uid = event.iCalUID?.lowercased(), uids.contains(uid) { return false }
            return !signatures.contains(signature(event))
        }
        return (eventKit + extra).sorted { $0.start < $1.start }
    }

    private static func signature(_ event: CalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(title)|\(Int(event.start.timeIntervalSince1970 / 60))|\(Int(event.end.timeIntervalSince1970 / 60))"
    }
}

public struct ReminderItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var title: String
    public var due: Date?
    /// Whether `due` carries a time (otherwise date-only).
    public var hasDueTime: Bool
    public var isCompleted: Bool
    public var listName: String?
    public var notes: String?

    public init(
        id: String, title: String, due: Date?, hasDueTime: Bool = true, isCompleted: Bool = false,
        listName: String? = nil, notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.hasDueTime = hasDueTime
        self.isCompleted = isCompleted
        self.listName = listName
        self.notes = notes
    }
}

public struct ReminderGroups: Sendable, Equatable {
    public var overdue: [ReminderItem]
    public var today: [ReminderItem]

    public init(overdue: [ReminderItem], today: [ReminderItem]) {
        self.overdue = overdue
        self.today = today
    }

    public var isEmpty: Bool { overdue.isEmpty && today.isEmpty }
    public var count: Int { overdue.count + today.count }

    /// Splits incomplete reminders into overdue and due-today.
    public static func group(_ reminders: [ReminderItem], now: Date, calendar: Calendar = .current) -> ReminderGroups {
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return ReminderGroups(overdue: [], today: [])
        }
        var overdue: [ReminderItem] = []
        var today: [ReminderItem] = []
        for reminder in reminders where !reminder.isCompleted {
            guard let due = reminder.due else { continue }
            let isOverdue = reminder.hasDueTime ? due < now : due < startOfDay
            if isOverdue {
                overdue.append(reminder)
            } else if due < endOfDay {
                today.append(reminder)
            }
        }
        let byDue: (ReminderItem, ReminderItem) -> Bool = { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        return ReminderGroups(overdue: overdue.sorted(by: byDue), today: today.sorted(by: byDue))
    }
}

/// Compact countdown text ("dans 5 min", "en cours", "dans 2 h 05").
public enum CountdownFormatter {
    public static func string(until start: Date, end: Date? = nil, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 {
            if let end, now < end { return "En cours" }
            return "Commencé"
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Dans \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "Dans \(hours) h" : String(format: "Dans %d h %02d", hours, rest)
    }

    /// Time left without "Dans", shown beside the circular hourglass: "12 min", "1 h 05", "< 1 min".
    public static func short(until start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "Maintenant" }
        if seconds < 60 { return "< 1 min" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }
}
