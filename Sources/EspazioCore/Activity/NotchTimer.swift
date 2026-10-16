import Foundation

/// A countdown shown in the notch: plain timer, or a Pomodoro focus period followed by a break.
public struct NotchTimer: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case timer
        /// Pomodoro work period; a break follows automatically.
        case focus
        /// Pomodoro break.
        case pause

        public var label: String {
            switch self {
            case .timer: return "Minuteur"
            case .focus: return "Concentration"
            case .pause: return "Pause"
            }
        }

        public var symbol: String {
            switch self {
            case .timer: return "timer"
            case .focus: return "brain.head.profile"
            case .pause: return "cup.and.saucer"
            }
        }
    }

    public var kind: Kind
    public var start: Date
    public var end: Date

    public init(kind: Kind, start: Date, duration: TimeInterval) {
        self.kind = kind
        self.start = start
        self.end = start.addingTimeInterval(duration)
    }

    public static let focusDuration: TimeInterval = 25 * 60
    public static let pauseDuration: TimeInterval = 5 * 60

    /// What starts when this one ends: a break after a focus period, nothing otherwise.
    public func next(at date: Date) -> NotchTimer? {
        kind == .focus ? NotchTimer(kind: .pause, start: date, duration: Self.pauseDuration) : nil
    }
}

/// "25:00", "4:05", "1:02:03".
public enum TimerFormatter {
    public static func remaining(until end: Date, now: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "25 min", "1 h 30", "45 s".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", minutes))"
    }
}

/// Parses timer commands typed in Quick Actions: `25 min`, `10m`, `1h30`, `minuteur 5`,
/// `timer 90s`, `pomodoro`, `focus 50`.
public enum TimerParser {
    public struct Parsed: Sendable, Equatable {
        public var kind: NotchTimer.Kind
        public var duration: TimeInterval

        public init(kind: NotchTimer.Kind, duration: TimeInterval) {
            self.kind = kind
            self.duration = duration
        }
    }

    static let maximum: TimeInterval = 12 * 3600
    private static let timerPrefixes = ["minuteur", "timer", "chrono", "compte a rebours"]
    private static let focusPrefixes = ["pomodoro", "pomo", "focus", "concentration"]

    public static func parse(_ input: String) -> Parsed? {
        let text = QuickActionSearch.normalize(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let prefix = focusPrefixes.first(where: { text == $0 || text.hasPrefix($0 + " ") }) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return Parsed(kind: .focus, duration: NotchTimer.focusDuration) }
            return duration(rest, bareNumberIsMinutes: true).map { Parsed(kind: .focus, duration: $0) }
        }
        if let prefix = timerPrefixes.first(where: { text == $0 || text.hasPrefix($0 + " ") }) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return duration(rest, bareNumberIsMinutes: true).map { Parsed(kind: .timer, duration: $0) }
        }
        // Without a keyword a unit is required, so a search for "25" is not a timer.
        return duration(text, bareNumberIsMinutes: false).map { Parsed(kind: .timer, duration: $0) }
    }

    /// `25`, `25 min`, `25mn`, `10m`, `90s`, `90 sec`, `1h`, `1h30`, `1 h 30`.
    static func duration(_ raw: String, bareNumberIsMinutes: Bool) -> TimeInterval? {
        let text = raw.replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty, let first = text.first, first.isNumber else { return nil }
        var seconds: TimeInterval?
        if let h = text.firstIndex(of: "h") {
            guard let hours = Int(text[..<h]) else { return nil }
            var rest = String(text[text.index(after: h)...])
            for unit in ["min", "mn", "m"] where rest.hasSuffix(unit) { rest.removeLast(unit.count); break }
            let minutes = rest.isEmpty ? 0 : Int(rest)
            guard let minutes, (0..<60).contains(minutes) else { return nil }
            seconds = TimeInterval(hours * 3600 + minutes * 60)
        } else {
            let digits = text.prefix(while: \.isNumber)
            guard let value = Int(digits) else { return nil }
            let unit = String(text.dropFirst(digits.count))
            switch unit {
            case "": seconds = bareNumberIsMinutes ? TimeInterval(value * 60) : nil
            case "min", "mn", "m", "minute", "minutes": seconds = TimeInterval(value * 60)
            case "s", "sec", "secondes", "seconde": seconds = TimeInterval(value)
            default: return nil
            }
        }
        guard let seconds, seconds >= 1, seconds <= maximum else { return nil }
        return seconds
    }
}

/// Recent text copied to the clipboard, kept in memory only (never written to disk) and only
/// when the clipboard module is on. Password managers' concealed items are skipped upstream.
public struct ClipboardHistory: Sendable, Equatable {
    public private(set) var items: [String] = []
    public let capacity: Int
    public static let maxLength = 4000

    public init(capacity: Int = 5) {
        self.capacity = capacity
    }

    /// Adds a copied text (most recent first, no duplicates). Returns whether it was kept.
    @discardableResult
    public mutating func add(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maxLength else { return false }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
        return true
    }

    public mutating func clear() { items.removeAll() }
}
