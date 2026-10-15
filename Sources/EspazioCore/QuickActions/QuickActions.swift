import Foundation

/// An entry of the Quick Actions palette (spec §3.8).
public struct QuickActionItem: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
        case createReminder(title: String, due: Date?, hasDueTime: Bool)
        case openEvent(id: String)
        case joinMeeting(URL)
        case openSession(id: String)
        case openMail(id: String)
        case openChat(spaceID: String)
        case openMessages
        case completeReminder(id: String)
        case toggleSilentMode
    }

    public let id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String
    public var action: Action
    /// Extra words matched by the search but not displayed.
    public var keywords: [String]

    public init(id: String, title: String, subtitle: String? = nil, symbol: String, action: Action, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.action = action
        self.keywords = keywords
    }
}

public enum QuickActionSearch {
    /// Ranks catalog entries for a query and prepends a "create reminder" action when the query
    /// looks like one. Purely local: only already-synchronized content is searched.
    public static func results(
        for query: String, catalog: [QuickActionItem], now: Date, calendar: Calendar = .current, limit: Int = 8
    ) -> [QuickActionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var output: [QuickActionItem] = []
        if let reminder = ReminderParser.parseCommand(trimmed, now: now, calendar: calendar) {
            let subtitle = reminder.due.map { due in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "fr_FR")
                formatter.dateStyle = .medium
                formatter.timeStyle = reminder.hasDueTime ? .short : .none
                return "Échéance : " + formatter.string(from: due)
            } ?? "Sans échéance"
            output.append(QuickActionItem(
                id: "create-reminder", title: "Nouveau rappel : \(reminder.title)", subtitle: subtitle,
                symbol: "plus.circle", action: .createReminder(title: reminder.title, due: reminder.due, hasDueTime: reminder.hasDueTime)))
        }
        guard !trimmed.isEmpty else { return Array((output + catalog).prefix(limit)) }
        let needle = normalize(trimmed)
        let scored = catalog.compactMap { item -> (QuickActionItem, Int)? in
            let haystacks = [item.title, item.subtitle ?? ""] + item.keywords
            let best = haystacks.map { score(needle: needle, in: normalize($0)) }.max() ?? 0
            return best > 0 ? (item, best) : nil
        }
        let ranked = scored.sorted { $0.1 > $1.1 }.map(\.0)
        return Array((output + ranked).prefix(limit))
    }

    /// Prefix > word prefix > substring > subsequence.
    static func score(needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        if haystack.hasPrefix(needle) { return 100 }
        if haystack.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 80 }
        if haystack.contains(needle) { return 60 }
        // Loose subsequence match, anchored on the start of a word to avoid noise.
        guard let first = needle.first,
            let anchor = haystack.split(separator: " ").first(where: { $0.first == first })
        else { return 0 }
        var index = anchor.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return 0 }
            index = haystack.index(after: found)
        }
        return 20
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
}

/// Parses natural reminder commands: `+ acheter du pain demain 9h`, `rappel: appeler Paul à 14h30`.
public enum ReminderParser {
    public struct Parsed: Sendable, Equatable {
        public var title: String
        public var due: Date?
        public var hasDueTime: Bool
    }

    private static let prefixes = ["+", "rappel:", "rappel ", "remind ", "todo:", "todo "]

    public static func parseCommand(_ input: String, now: Date, calendar: Calendar = .current) -> Parsed? {
        let lower = input.lowercased()
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let body = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return parse(body, now: now, calendar: calendar)
    }

    public static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> Parsed {
        var words = text.split(separator: " ").map(String.init)
        var dayOffset: Int?
        var time: (hour: Int, minute: Int)?

        var index = 0
        while index < words.count {
            let word = QuickActionSearch.normalize(words[index]).trimmingCharacters(in: .punctuationCharacters)
            var consumed = 0
            switch word {
            case "aujourd'hui", "aujourdhui", "today":
                dayOffset = 0; consumed = 1
            case "demain", "tomorrow":
                dayOffset = 1; consumed = 1
            case "apres-demain":
                dayOffset = 2; consumed = 1
            case "ce" where index + 1 < words.count && QuickActionSearch.normalize(words[index + 1]) == "soir":
                dayOffset = dayOffset ?? 0
                time = time ?? (19, 0)
                consumed = 2
            case "a", "at":
                if index + 1 < words.count, let parsed = parseTime(words[index + 1]) {
                    time = parsed; consumed = 2
                }
            default:
                if let parsed = parseTime(word) { time = parsed; consumed = 1 }
            }
            if consumed > 0 {
                words.removeSubrange(index..<(index + consumed))
            } else {
                index += 1
            }
        }

        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard dayOffset != nil || time != nil else {
            return Parsed(title: title.isEmpty ? text : title, due: nil, hasDueTime: false)
        }
        let startOfToday = calendar.startOfDay(for: now)
        var day = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: startOfToday) ?? startOfToday
        guard let time else {
            return Parsed(title: title, due: day, hasDueTime: false)
        }
        var due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
        if dayOffset == nil && due <= now {
            // "à 9h" when it is already 10h means tomorrow.
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? due
        }
        return Parsed(title: title.isEmpty ? text : title, due: due, hasDueTime: true)
    }

    /// Accepts `9h`, `9h30`, `14:30`, `14h`.
    static func parseTime(_ raw: String) -> (hour: Int, minute: Int)? {
        let token = raw.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: ":")))
        let separators: [Character] = ["h", ":"]
        guard let separator = token.first(where: { separators.contains($0) }) else { return nil }
        let parts = token.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        if parts[1].isEmpty { return separator == "h" ? (hour, 0) : nil }
        guard parts[1].count == 2, let minute = Int(parts[1]), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }
}
