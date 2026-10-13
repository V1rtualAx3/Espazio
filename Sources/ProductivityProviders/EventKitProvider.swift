import AppKit
import EspazioCore
@preconcurrency import EventKit

/// Calendar and Reminders through EventKit. The two permissions are requested independently,
/// only on user action. Refreshes are driven by `EKEventStoreChanged` (debounced) and by a single
/// timer aligned on the next relevant boundary — never by polling.
@MainActor
public final class EventKitProvider {
    public var onEvents: (([CalendarEvent]) -> Void)?
    public var onReminders: (([ReminderItem]) -> Void)?
    public var onAccessChange: (() -> Void)?

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    public var lookahead: TimeInterval = 24 * 3600
    public var eventsEnabled = false
    public var remindersEnabled = false

    public init() {}

    // MARK: - Authorization

    public enum Access: Sendable, Equatable {
        case notDetermined, granted, denied, restricted
    }

    public static func access(for type: EKEntityType) -> Access {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    public func requestEventsAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        onAccessChange?()
        if granted { reloadEvents() }
        return granted
    }

    public func requestRemindersAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        onAccessChange?()
        if granted { reloadReminders() }
        return granted
    }

    // MARK: - Lifecycle

    public func start() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reloadAll()
    }

    public func stop() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        debounceTask?.cancel()
    }

    public func reloadAll() {
        reloadEvents()
        reloadReminders()
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadAll()
        }
    }

    // MARK: - Events

    public func reloadEvents() {
        guard eventsEnabled, Self.access(for: .event) == .granted else {
            onEvents?([])
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(lookahead), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.end > now && $0.status != .canceled }
            .prefix(40)
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "Sans titre",
                    start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, location: event.location,
                    notes: event.notes.map { String($0.prefix(2000)) }, url: event.url, calendarName: event.calendar?.title,
                    source: .eventKit, iCalUID: event.calendarItemExternalIdentifier)
            }
            .sorted { $0.start < $1.start }
        onEvents?(Array(events))
    }

    /// Opens the event in Calendar. `ical://ekevent/<id>` is the scheme Calendar registers; when it
    /// is not handled, Calendar is opened on the event date instead.
    public func open(_ event: CalendarEvent) {
        let encoded = event.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.id
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"), NSWorkspace.shared.open(url) {
            return
        }
        if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendarApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Reminders

    public func reloadReminders() {
        guard remindersEnabled, Self.access(for: .reminder) == .granted else {
            onReminders?([])
            return
        }
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            // Map on the EventKit queue: only Sendable values cross to the main actor.
            let items: [ReminderItem] = (reminders ?? []).prefix(100).map { reminder in
                let components = reminder.dueDateComponents
                let due = components.flatMap { Calendar.current.date(from: $0) }
                return ReminderItem(
                    id: reminder.calendarItemIdentifier, title: reminder.title ?? "Sans titre", due: due,
                    hasDueTime: components?.hour != nil, isCompleted: reminder.isCompleted, listName: reminder.calendar?.title,
                    notes: nil)
            }
            Task { @MainActor in self?.onReminders?(items) }
        }
    }

    public func completeReminder(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        reloadReminders()
    }

    public func createReminder(title: String, due: Date?, hasDueTime: Bool) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw NSError(domain: "Espazio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Aucune liste de rappels par défaut."])
        }
        reminder.calendar = calendar
        if let due {
            let units: Set<Calendar.Component> = hasDueTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
            if hasDueTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
        reloadReminders()
    }

    public func openRemindersApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
