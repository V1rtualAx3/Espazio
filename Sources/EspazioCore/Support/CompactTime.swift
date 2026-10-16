import Foundation

/// Short French timestamps for message lists: "maintenant", "5 min", "14:32", "hier", "lun.",
/// "03/10".
public enum CompactTime {
    public static func string(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "maintenant" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days == 1 { return "hier" }
        formatter.dateFormat = days < 7 ? "EEE" : "dd/MM"
        return formatter.string(from: date)
    }
}
