import AgentIntegrations
import AppKit
import EspazioBridge
import EspazioCore
import EspazioUI
import GoogleProvider
import ProductivityProviders
import SystemServices

/// Central coordinator: single source of truth (`EspazioState`), activity routing, module
/// lifecycle and every user action. Lives on the main actor; heavy work happens in actors and
/// providers.
@MainActor
final class AppCoordinator: EspazioActions, SettingsActions, WelcomeActions {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Espazio", isDirectory: true)
    }()

    let state = EspazioState()
    let launchDate = Date()
    private var router = ActivityRouter()
    private var expiryTimer: Timer?
    private var scheduleTimer: Timer?
    private var liveTimer: Timer?

    // Modules
    let media = MediaHub()
    let audio = AudioMonitor()
    let power = PowerMonitor()
    let keyboard = KeyboardMonitor()
    private var bluetooth: BluetoothMonitor?
    let eventKit = EventKitProvider()
    var eventKitEvents: [CalendarEvent] = []
    var googleEvents: [CalendarEvent] = []
    var remindersAll: [ReminderItem] = []
    private var notifiedSchedule: Set<String> = []

    // Agents
    let audit: AuditLog
    let approvals: ApprovalCenter
    var sessionStore = AgentSessionStore()
    var bridge: BridgeServer?
    var codexClient: CodexAppServerClient?
    var codexTransport: ProcessLineTransport?
    var codexIdleTask: Task<Void, Never>?
    private var approvalsTask: Task<Void, Never>?
    private var postedApprovalIDs: Set<String> = []
    var chatGPTObservers: [NSObjectProtocol] = []

    // Google
    var google: GoogleController?

    // UI
    private(set) var display: DisplayManager!
    private var statusItem: StatusItemController?
    let quickActions = QuickActionsController()
    private(set) var settingsWindow: SettingsWindowController!
    private var welcomeWindow: WelcomeWindowController?
    private let hotKeys = HotKeyCenter()
    let updates = UpdateController()
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let settingsKey = "settings.v1"

    init() {
        let audit = AuditLog(fileURL: Self.supportDirectory.appendingPathComponent("audit.log"))
        self.audit = audit
        approvals = ApprovalCenter(audit: { event in audit.record(event) })
        state.settings = EspazioSettings.decode(UserDefaults.standard.data(forKey: Self.settingsKey))
        display = DisplayManager(state: state, coordinator: self)
        settingsWindow = SettingsWindowController(state: state, actions: self)
    }

    // MARK: - Lifecycle

    func start() {
        state.launchAtLogin = LaunchAtLogin.isEnabled
        state.updatesConfigured = updates.isConfigured
        state.automaticUpdateChecks = updates.automaticallyChecks
        statusItem = StatusItemController(coordinator: self)
        quickActions.onExecute = { [weak self] item in self?.perform(item) }
        applyPolicy()
        startSystemModules()
        startProductivity()
        startAgents()
        google = GoogleController(coordinator: self)
        google?.start()
        registerHotKeys()
        observeSleep()
        display.start()
        if !state.settings.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showWelcome() }
        }
    }

    func shutdown() {
        bridge?.stop()
        codexTransport?.close()
        google?.stop()
        audio.stop()
        power.stop()
        keyboard.stop()
        bluetooth?.stop()
        // A normal quit is not a crash during the Bluetooth start-up.
        UserDefaults.standard.removeObject(forKey: Self.bluetoothStartingKey)
        media.stopAll()
        eventKit.stop()
        display.stop()
        audit.flush()
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.google?.pause() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.google?.resume(after: 10)
                self?.eventKit.reloadAll()
                self?.rescheduleTimers()
            }
        })
    }

    // MARK: - Settings

    func updateSettings(_ newValue: EspazioSettings) {
        let old = state.settings
        let settings = newValue.normalized()
        guard settings != old else { return }
        state.settings = settings
        UserDefaults.standard.set(settings.encoded(), forKey: Self.settingsKey)
        applyPolicy()
        if settings.displayMode != old.displayMode || settings.hideInFullScreen != old.hideInFullScreen {
            display.rebuild()
        }
        if settings.modules != old.modules {
            restartModules(old: old.modules, new: settings.modules)
        }
        if settings.live != old.live || settings.modules != old.modules {
            refreshLiveActivity()
        }
        if settings.googleSyncInterval != old.googleSyncInterval || settings.googleClientID != old.googleClientID {
            google?.restart()
        }
        if settings.quickActionsShortcut != old.quickActionsShortcut || settings.toggleNotchShortcut != old.toggleNotchShortcut {
            registerHotKeys()
        }
    }

    private func restartModules(old: ModuleSettings, new: ModuleSettings) {
        if old.media != new.media || old.spotify != new.spotify || old.appleMusic != new.appleMusic {
            new.media ? media.configure(spotify: new.spotify, appleMusic: new.appleMusic) : stopMedia()
        }
        if old.volume != new.volume || old.audioDevice != new.audioDevice {
            (new.volume || new.audioDevice) ? audio.start() : audio.stop()
        }
        if old.battery != new.battery { new.battery ? power.start() : power.stop() }
        if old.keyboard != new.keyboard { new.keyboard ? keyboard.start() : keyboard.stop() }
        if old.bluetooth != new.bluetooth { configureBluetooth(new.bluetooth) }
        if old.calendar != new.calendar || old.reminders != new.reminders {
            eventKit.eventsEnabled = new.calendar
            eventKit.remindersEnabled = new.reminders
            eventKit.reloadAll()
        }
        if old.claudeCode != new.claudeCode || old.codex != new.codex { configureBridge() }
        if old.chatGPT != new.chatGPT { configureChatGPT() }
        if old.gmail != new.gmail || old.googleChat != new.googleChat || old.googleCalendar != new.googleCalendar {
            google?.restart()
        }
        for source in new.mutedSources { router.dismissAll(from: source) }
        publish()
    }

    private func applyPolicy() {
        let settings = state.settings
        router.policy.mode = settings.focusMode
        router.policy.mutedSources = settings.modules.mutedSources
        if !settings.contextualFocus { router.policy.context = FocusContext() }
        publish()
    }

    func updateFocusContext(isFullScreen: Bool? = nil, isInMeeting: Bool? = nil) {
        guard state.settings.contextualFocus else { return }
        var context = router.policy.context
        if let isFullScreen { context.isFullScreen = isFullScreen }
        if let isInMeeting { context.isInMeeting = isInMeeting }
        guard context != router.policy.context else { return }
        router.policy.context = context
        publish()
    }

    // MARK: - Activities

    func post(_ item: ActivityItem) {
        let outcome = router.post(item, now: Date())
        switch outcome {
        case .muted, .duplicate:
            return
        default:
            publish()
        }
    }

    func dismissActivity(key: String) {
        if router.dismiss(coalescingKey: key) != nil { publish() }
    }

    /// Pushes the router state to the UI and schedules the single expiry timer.
    func publish() {
        _ = router.expire(now: Date())
        // In silent mode nothing peeks: pending decisions show as a dot under the collapsed notch.
        let peek = router.peekCandidate
        if state.peek != peek { state.peek = peek }
        state.activityCount = router.items.count
        state.pendingDecisionCount = router.pendingDecisionCount
        display?.syncPeek()
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let next = router.nextExpiry else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.01), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Tab to open when the user expands the notch from a peek.
    func preferredTab() -> NotchTab {
        if !state.pendingRequests.isEmpty { return .agents }
        switch state.peek?.source {
        case .agents: return .agents
        case .mail where state.visibleTabs.contains(.mail): return .mail
        case .chat where state.visibleTabs.contains(.chat): return .chat
        default: return .home
        }
    }

    // MARK: - System modules

    private func startSystemModules() {
        let modules = state.settings.modules
        audio.onEvent = { [weak self] event in self?.handleSystem(event) }
        power.onEvent = { [weak self] event in self?.handleSystem(event) }
        keyboard.onEvent = { [weak self] event in self?.handleSystem(event) }
        if modules.volume || modules.audioDevice { audio.start() }
        state.outputDeviceName = audio.currentDeviceName
        if modules.battery { power.start() }
        state.power = power.status
        if modules.keyboard { keyboard.start() }
        state.capsLock = modules.keyboard ? .value(keyboard.capsLockOn) : .unavailable(reason: "Module désactivé")
        configureBluetooth(modules.bluetooth)

        media.onChange = { [weak self] playing, name in
            self?.state.mediaPlayerName = name
            self?.handleNowPlaying(playing)
        }
        media.onArtwork = { [weak self] image in self?.state.artwork = image }
        if modules.media { media.configure(spotify: modules.spotify, appleMusic: modules.appleMusic) }
        state.mediaAvailable = media.isAnyRunning
    }

    /// Set while the Bluetooth module starts; still set at the next launch means the app died
    /// there, and the module is turned off instead of crashing again at every launch.
    private static let bluetoothStartingKey = "bluetooth.starting"

    private func configureBluetooth(_ enabled: Bool) {
        let defaults = UserDefaults.standard
        if enabled, defaults.bool(forKey: Self.bluetoothStartingKey) {
            defaults.removeObject(forKey: Self.bluetoothStartingKey)
            var settings = state.settings
            settings.modules.bluetooth = false
            updateSettings(settings)
            showError("Bluetooth désactivé : Espazio s’est arrêté pendant son démarrage. Vous pouvez le réactiver dans les réglages.")
            return
        }
        if enabled {
            defaults.set(true, forKey: Self.bluetoothStartingKey)
            let monitor = bluetooth ?? BluetoothMonitor()
            monitor.onEvent = { [weak self] event in self?.handleSystem(event) }
            monitor.start()
            bluetooth = monitor
            // Connect notifications for already-connected devices arrive within the first seconds.
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                defaults.removeObject(forKey: Self.bluetoothStartingKey)
            }
        } else {
            bluetooth?.stop()
            bluetooth = nil
        }
    }

    private func handleSystem(_ event: SystemEvent) {
        let modules = state.settings.modules
        switch event {
        case .volume:
            guard modules.volume else { return }
        case let .outputDeviceChanged(name):
            state.outputDeviceName = name
            guard modules.audioDevice else { return }
        case let .power(status, _):
            state.power = status
        case let .capsLock(isOn):
            state.capsLock = .value(isOn)
        case .bluetooth:
            break
        }
        if let item = SystemEventMapper.activity(for: event, now: Date()) { post(item) }
    }

    private func handleNowPlaying(_ playing: NowPlaying?) {
        let previous = state.nowPlaying
        state.nowPlaying = playing
        state.mediaAvailable = media.isAnyRunning
        let now = Date()
        guard let playing else {
            refreshLiveActivity()
            return
        }
        if playing.state == .playing, previous?.trackID != playing.trackID, previous != nil {
            post(ActivityItem(
                source: .media, priority: .p3, coalescingKey: PeekKeys.trackChange, title: playing.title,
                subtitle: playing.artist, symbol: "music.note", createdAt: now, expiresAt: now.addingTimeInterval(3)))
        }
        refreshLiveActivity()
    }

    // MARK: - Continuous information ("affichage continu")

    /// Re-selects the single item kept in the notch at rest and schedules one timer for the next
    /// moment the choice can change by itself (a meeting entering its lead window or ending).
    func refreshLiveActivity() {
        let now = Date()
        let modules = state.settings.modules
        let agentSessions = state.sessions.filter { session in
            switch session.provider {
            case .claudeCode: return modules.claudeCode
            case .codex: return modules.codex
            case .chatGPT: return modules.chatGPT
            }
        }
        let inputs = LiveActivityInputs(
            nowPlaying: modules.media ? state.nowPlaying : nil,
            nextEvent: (modules.calendar || modules.googleCalendar) ? state.nextEvent(now: now) : nil,
            waitingAgents: agentSessions.filter { $0.state == .waiting }.count,
            activeAgents: agentSessions.filter { $0.state == .active }.count,
            unreadMail: modules.gmail ? state.unreadCount : nil,
            unreadChats: modules.googleChat ? state.chatUnread.count : 0)
        let settings = state.settings.live
        let selected = LiveActivityPlanner.select(inputs, settings: settings, now: now)
        var changed = false
        for key in LiveActivityKey.all where key != selected?.coalescingKey {
            if router.dismiss(coalescingKey: key) != nil { changed = true }
        }
        if let selected {
            switch router.post(selected, now: now) {
            case .duplicate, .muted: break
            default: changed = true
            }
        }
        if changed { publish() }

        liveTimer?.invalidate()
        liveTimer = nil
        if let next = LiveActivityPlanner.nextChange(inputs, settings: settings, now: now) {
            let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLiveActivity() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
        }
    }

    private func stopMedia() {
        media.stopAll()
        state.nowPlaying = nil
        state.artwork = nil
        dismissActivity(key: PeekKeys.nowPlaying)
    }

    // MARK: - Productivity

    private func startProductivity() {
        eventKit.eventsEnabled = state.settings.modules.calendar
        eventKit.remindersEnabled = state.settings.modules.reminders
        eventKit.onEvents = { [weak self] events in
            self?.eventKitEvents = events
            self?.mergeEvents()
        }
        eventKit.onReminders = { [weak self] reminders in
            guard let self else { return }
            self.remindersAll = reminders
            self.state.reminders = ReminderGroups.group(reminders, now: Date())
            self.rescheduleTimers()
        }
        eventKit.onAccessChange = { [weak self] in self?.refreshAccess() }
        refreshAccess()
        eventKit.start()
    }

    private func refreshAccess() {
        state.calendarAccess = Self.map(EventKitProvider.access(for: .event))
        state.remindersAccess = Self.map(EventKitProvider.access(for: .reminder))
    }

    private static func map(_ access: EventKitProvider.Access) -> AccessState {
        switch access {
        case .granted: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        }
    }

    func mergeEvents() {
        state.events = CalendarDeduplicator.merge(eventKit: eventKitEvents, google: googleEvents)
        rescheduleTimers()
        refreshLiveActivity()
    }

    /// One timer aligned on the next boundary that matters (5 min before an event, its start or
    /// end, a reminder due time, midnight) instead of polling.
    func rescheduleTimers() {
        scheduleTimer?.invalidate()
        let now = Date()
        updateFocusContext(isInMeeting: state.events.contains { $0.isOngoing(at: now) })
        var candidates: [Date] = []
        for event in state.events where !event.isAllDay {
            let warning = event.start.addingTimeInterval(-300)
            if warning > now { candidates.append(warning) } else if event.start > now, !notifiedSchedule.contains("event:\(event.id)") {
                notifyEvent(event, now: now)
            }
            if event.start > now { candidates.append(event.start) }
            if event.end > now { candidates.append(event.end) }
        }
        for reminder in remindersAll where !reminder.isCompleted && reminder.hasDueTime {
            guard let due = reminder.due else { continue }
            if due > now {
                candidates.append(due)
            } else if now.timeIntervalSince(due) < 60, !notifiedSchedule.contains("reminder:\(reminder.id)") {
                notifyReminder(reminder, now: now)
            }
        }
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            candidates.append(midnight)
        }
        guard let next = candidates.filter({ $0 > now }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.reminders = ReminderGroups.group(self.remindersAll, now: Date())
                self.rescheduleTimers()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    private func notifyEvent(_ event: CalendarEvent, now: Date) {
        if notifiedSchedule.count > 500 { notifiedSchedule.removeAll() }
        notifiedSchedule.insert("event:\(event.id)")
        post(ActivityItem(
            source: .calendar, priority: .p1, coalescingKey: "event:\(event.id)", title: event.title,
            subtitle: CountdownFormatter.string(until: event.start, now: now), symbol: "calendar", reference: event.id,
            createdAt: now, expiresAt: event.start.addingTimeInterval(60)))
    }

    private func notifyReminder(_ reminder: ReminderItem, now: Date) {
        notifiedSchedule.insert("reminder:\(reminder.id)")
        post(ActivityItem(
            source: .reminders, priority: .p1, coalescingKey: "reminder:\(reminder.id)", title: reminder.title,
            subtitle: "Rappel", symbol: "checklist", reference: reminder.id, createdAt: now, expiresAt: now.addingTimeInterval(10)))
    }

    // MARK: - Shortcuts & palette

    private func registerHotKeys() {
        let settings = state.settings
        var refused: [String] = []
        if !hotKeys.register(id: 1, shortcut: settings.quickActionsShortcut, handler: { [weak self] in self?.toggleQuickActions() }) {
            refused.append(settings.quickActionsShortcut.displayString)
        }
        if !hotKeys.register(id: 2, shortcut: settings.toggleNotchShortcut, handler: { [weak self] in self?.toggleNotch() }) {
            refused.append(settings.toggleNotchShortcut.displayString)
        }
        if !refused.isEmpty {
            settingsWindow.lastError = "Raccourci déjà utilisé par une autre application : \(refused.joined(separator: ", "))."
        }
    }

    func toggleNotch() {
        display.toggle(tab: preferredTab())
    }

    func toggleQuickActions() {
        quickActions.toggle(catalog: quickActionCatalog())
    }

    func quickActionCatalog() -> [QuickActionItem] {
        var items: [QuickActionItem] = []
        if let event = state.nextEvent(now: Date()) {
            items.append(QuickActionItem(
                id: "next-event", title: event.title, subtitle: "Prochain événement · " + CountdownFormatter.string(until: event.start, end: event.end, now: Date()),
                symbol: "calendar", action: .openEvent(id: event.id), keywords: ["prochain", "événement", "agenda"]))
            if let url = event.meetingURL {
                items.append(QuickActionItem(id: "join", title: "Rejoindre : \(event.title)", symbol: "video", action: .joinMeeting(url), keywords: ["réunion", "visio"]))
            }
        }
        for event in state.events.prefix(10) where event.id != state.nextEvent(now: Date())?.id {
            items.append(QuickActionItem(id: "event:\(event.id)", title: event.title, subtitle: event.start.formatted(date: .abbreviated, time: .shortened), symbol: "calendar", action: .openEvent(id: event.id)))
        }
        for reminder in state.reminders.overdue + state.reminders.today {
            items.append(QuickActionItem(id: "reminder:\(reminder.id)", title: "Terminer : \(reminder.title)", symbol: "checkmark.circle", action: .completeReminder(id: reminder.id), keywords: ["rappel"]))
        }
        for session in state.sessions {
            items.append(QuickActionItem(id: "session:\(session.id)", title: session.projectName, subtitle: session.provider.displayName, symbol: "terminal", action: .openSession(id: session.id), keywords: ["ia", "agent"]))
        }
        for mail in state.mail {
            items.append(QuickActionItem(id: "mail:\(mail.id)", title: mail.subject, subtitle: mail.senderName, symbol: "envelope", action: .openMail(id: mail.id), keywords: ["mail"]))
        }
        for chat in state.chatUnread.prefix(10) {
            items.append(QuickActionItem(id: "chat:\(chat.id)", title: chat.title, subtitle: "Google Chat · non lu", symbol: "bubble.left", action: .openChat(spaceID: chat.id)))
        }
        items.append(QuickActionItem(
            id: "silent", title: state.settings.focusMode == .silent ? "Désactiver le mode silencieux" : "Activer le mode silencieux",
            symbol: "bell.slash", action: .toggleSilentMode, keywords: ["concentration", "focus"]))
        return items
    }

    private func perform(_ item: QuickActionItem) {
        switch item.action {
        case let .createReminder(title, due, hasDueTime):
            createReminder(title: title, due: due, hasDueTime: hasDueTime)
        case let .openEvent(id):
            if let event = state.events.first(where: { $0.id == id }) { openEvent(event) }
        case let .joinMeeting(url):
            joinMeeting(url)
        case let .openSession(id):
            if let session = state.sessions.first(where: { $0.id == id }) { openSession(session) }
        case let .openMail(id):
            if let mail = state.mail.first(where: { $0.id == id }) { openMail(mail) }
        case let .openChat(spaceID):
            if let chat = state.chatUnread.first(where: { $0.id == spaceID }) { openChat(chat) }
        case let .completeReminder(id):
            completeReminder(id: id)
        case .toggleSilentMode:
            setFocusMode(state.settings.focusMode == .silent ? .normal : .silent)
        }
    }

    // MARK: - EspazioActions (media, productivity, app)

    func togglePlayPause() { media.playPause() }
    func nextTrack() { media.next() }
    func previousTrack() { media.previous() }
    func openMediaApp() { media.openApp() }

    func requestCalendarAccess() {
        Task { _ = await eventKit.requestEventsAccess() }
    }

    func requestRemindersAccess() {
        Task { _ = await eventKit.requestRemindersAccess() }
    }

    func openEvent(_ event: CalendarEvent) {
        if event.source == .google, let url = event.url {
            NSWorkspace.shared.open(url)
        } else {
            eventKit.open(event)
        }
        display.collapseAll()
    }

    func joinMeeting(_ url: URL) {
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
        display.collapseAll()
    }

    func completeReminder(id: String) {
        do {
            try eventKit.completeReminder(id: id)
        } catch {
            showError("Impossible de terminer le rappel.")
        }
    }

    func createReminder(title: String, due: Date?, hasDueTime: Bool) {
        guard state.remindersAccess == .granted else {
            requestRemindersAccess()
            return
        }
        do {
            try eventKit.createReminder(title: title, due: due, hasDueTime: hasDueTime)
            let now = Date()
            post(ActivityItem(source: .reminders, priority: .p3, coalescingKey: "reminder-created", title: "Rappel créé", subtitle: title,
                              symbol: "checkmark.circle", createdAt: now, expiresAt: now.addingTimeInterval(2.5)))
        } catch {
            showError("Impossible de créer le rappel.")
        }
    }

    func openReminders() { eventKit.openRemindersApp() }

    func setFocusMode(_ mode: FocusMode) {
        var settings = state.settings
        settings.focusMode = mode
        updateSettings(settings)
    }

    func openSettings() {
        display.collapseAll()
        settingsWindow.show()
    }

    func collapseNotch() { display.collapseAll() }

    func dismissPeek() {
        if let key = state.peek?.coalescingKey, state.peek?.requiresDecision == false { dismissActivity(key: key) }
    }

    func showError(_ message: String) {
        let now = Date()
        post(ActivityItem(source: .system, priority: .p2, coalescingKey: "error", title: message, symbol: "exclamationmark.triangle",
                          createdAt: now, expiresAt: now.addingTimeInterval(4)))
    }

    // MARK: - SettingsActions

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshDiagnostics() {
        state.diagnostics = Diagnostics.snapshot(
            launchDate: launchDate, notchWindows: display.controllers.count, activityItems: router.items.count,
            artworkCacheItems: media.artworkCacheCount, bridgeRunning: bridge?.isRunning ?? false,
            codexRunning: codexTransport?.isRunning ?? false)
    }

    // MARK: - Welcome

    func showWelcome() {
        let controller = welcomeWindow ?? WelcomeWindowController(state: state, actions: self)
        welcomeWindow = controller
        controller.show()
    }

    func finishWelcome() {
        welcomeWindow?.close()
        guard !state.settings.hasCompletedOnboarding else { return }
        var settings = state.settings
        settings.hasCompletedOnboarding = true
        updateSettings(settings)
    }

    func openGoogleSettings() {
        settingsWindow.show()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settingsWindow.lastError = LaunchAtLogin.set(enabled)
        state.launchAtLogin = LaunchAtLogin.isEnabled
    }

    func checkForUpdates() { updates.checkForUpdates() }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        updates.automaticallyChecks = enabled
        state.automaticUpdateChecks = updates.automaticallyChecks
    }

    func revealAuditLog() {
        NSWorkspace.shared.activateFileViewerSelecting([audit.fileURL])
    }

    // MARK: - Approvals → activities

    func observeApprovals() {
        approvalsTask?.cancel()
        let approvals = self.approvals
        approvalsTask = Task { [weak self] in
            let stream = await approvals.updates()
            for await requests in stream {
                self?.approvalsChanged(requests)
            }
        }
    }

    private func approvalsChanged(_ requests: [AgentRequest]) {
        state.pendingRequests = requests
        let ids = Set(requests.map(\.id))
        for removed in postedApprovalIDs.subtracting(ids) {
            router.dismiss(coalescingKey: "approval:\(removed)")
        }
        for request in requests where !postedApprovalIDs.contains(request.id) {
            router.post(ActivityItem(
                source: .agents, priority: .p0, coalescingKey: "approval:\(request.id)",
                title: request.kind.isQuestion ? "Question" : "Autoriser ?", subtitle: request.provider.displayName,
                symbol: request.kind.isQuestion ? "questionmark.bubble" : "exclamationmark.shield", reference: request.id,
                createdAt: request.createdAt, requiresDecision: true), now: Date())
        }
        postedApprovalIDs = ids
        publish()
    }
}
