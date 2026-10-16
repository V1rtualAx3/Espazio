import EspazioCore
import Foundation

/// Google Tasks API (https://developers.google.com/tasks): open tasks with a due date, shown with
/// the reminders (due today and overdue). Free, works with personal and Workspace accounts.
public struct GoogleTasksService: Sendable {
    static let base = "https://tasks.googleapis.com/tasks/v1"
    /// Prefix of the reminder IDs built from Google tasks: `gtask:<list>/<task>`.
    public static let idPrefix = "gtask:"
    let api: GoogleAPI

    public init(api: GoogleAPI) { self.api = api }

    /// Open tasks with a due date, from every list (bounded). Requires `tasks.readonly`.
    public func openTasks(calendar: Calendar = .current, maxLists: Int = 20) async throws -> [ReminderItem] {
        var components = URLComponents(string: "\(Self.base)/users/@me/lists")!
        components.queryItems = [URLQueryItem(name: "maxResults", value: String(maxLists))]
        let lists = try GoogleChatService.decode(try await api.get(components.url!))["items"]?.arrayValue ?? []
        var result: [ReminderItem] = []
        for list in lists {
            guard let listID = list["id"]?.stringValue else { continue }
            var tasks = URLComponents(string: "\(Self.base)/lists/\(Self.escape(listID))/tasks")!
            tasks.queryItems = [
                URLQueryItem(name: "showCompleted", value: "false"),
                URLQueryItem(name: "showHidden", value: "false"),
                URLQueryItem(name: "maxResults", value: "100"),
            ]
            let json = try GoogleChatService.decode(try await api.get(tasks.url!))
            result += Self.parseTasks(json, listID: listID, listName: list["title"]?.stringValue, calendar: calendar)
        }
        return result
    }

    /// Marks a task completed. Requires `tasks`.
    public func complete(reminderID: String) async throws {
        guard let (listID, taskID) = Self.split(reminderID) else { throw GoogleAPIError.invalidResponse }
        let url = URL(string: "\(Self.base)/lists/\(Self.escape(listID))/tasks/\(Self.escape(taskID))")!
        _ = try await api.patch(url, json: .object(["status": .string("completed")]))
    }

    public static func webURL() -> URL { URL(string: "https://tasks.google.com/")! }

    static func parseTasks(_ json: JSONValue, listID: String, listName: String?, calendar: Calendar) -> [ReminderItem] {
        var result: [ReminderItem] = []
        for task in json["items"]?.arrayValue ?? [] {
            guard let id = task["id"]?.stringValue, task["status"]?.stringValue != "completed",
                  task["deleted"]?.boolValue != true,
                  let due = dueDate(task["due"]?.stringValue, calendar: calendar)
            else { continue }
            let title = task["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Sans titre"
            result.append(ReminderItem(
                id: idPrefix + listID + "/" + id, title: title, due: due, hasDueTime: false,
                listName: listName.map { "Google Tasks · " + $0 } ?? "Google Tasks",
                notes: task["notes"]?.stringValue.map { String($0.prefix(500)) }))
        }
        return result
    }

    /// Tasks only keep the due *date* (sent as midnight UTC): the same calendar day, local time.
    static func dueDate(_ text: String?, calendar: Calendar) -> Date? {
        guard let text, let instant = GoogleChatService.parseDate(text) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.dateComponents([.year, .month, .day], from: instant)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    static func split(_ reminderID: String) -> (String, String)? {
        guard reminderID.hasPrefix(idPrefix) else { return nil }
        let rest = reminderID.dropFirst(idPrefix.count)
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let list = String(rest[..<slash]), task = String(rest[rest.index(after: slash)...])
        return list.isEmpty || task.isEmpty ? nil : (list, task)
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }
}
