import AppKit
import EspazioCore
import EspazioUI
import GoogleProvider

/// Google connectors: OAuth (PKCE + loopback, system browser — no WebView), exponential backoff,
/// rate limiting and progressive consent. Each connector has its own loop: Chat every 5 s (one
/// `spaces.list` request when nothing changed), Gmail every 30 s (one `history.list` request),
/// Calendar at the user's interval. Mail and Chat only report what is unread: Espazio points to
/// it, the user reads and answers in Gmail / Google Chat.
@MainActor
final class GoogleController {
    private weak var coordinator: AppCoordinator?
    private let http = URLSessionHTTPClient()
    /// Tokens and client secret in a single Keychain item (one access prompt per update).
    private let vault = GoogleCredentialVault(storage: KeychainSecretStorage(service: "app.espazio.google"))
    private var session: GoogleAuthSession?
    private var gmailMonitor: GmailMonitor?
    private var loops: [SyncKind: Task<Void, Never>] = [:]
    private var attempts: [SyncKind: Int] = [:]
    /// Delayed restart after a pause (system sleep, battery saver).
    private var resumeTask: Task<Void, Never>?

    enum SyncKind: CaseIterable {
        case chat, gmail, calendar, tasks
    }
    private var signInTask: Task<Void, Never>?
    /// ~13 requests a minute in steady state (12 Chat + 2 Gmail + Calendar), well within quotas.
    private var bucket = TokenBucket(capacity: 30, refillRate: 0.5, now: Date())
    private let backoff = ExponentialBackoff(base: 30, maximum: 30 * 60, jitter: 0.2)
    private var chatMonitor: ChatUnreadMonitor?
    private var paused = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    private var state: EspazioState? { coordinator?.state }
    private var modules: ModuleSettings { state?.settings.modules ?? ModuleSettings() }
    private var anyEnabled: Bool { modules.gmail || modules.googleChat || modules.googleCalendar || modules.googleTasks }

    // MARK: - Lifecycle

    func start() {
        session = makeSession()
        Task { await refreshStatuses() }
        guard anyEnabled, !paused else { return }
        startLoop()
    }

    func stop() {
        resumeTask?.cancel()
        resumeTask = nil
        loops.values.forEach { $0.cancel() }
        loops.removeAll()
    }

    func restart() {
        stop()
        attempts.removeAll()
        chatMonitor = nil
        state?.chatUnread = []
        Task { await gmailMonitor?.reset() }
        gmailMonitor = nil
        if !modules.googleCalendar {
            coordinator?.googleEvents = []
            coordinator?.mergeEvents()
        }
        if !modules.googleTasks {
            coordinator?.setGoogleTasks([])
        }
        start()
    }

    func pause() {
        paused = true
        stop()
    }

    func resume(after delay: TimeInterval) {
        paused = false
        guard anyEnabled else { return }
        stop()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startLoop()
        }
    }

    private func makeSession() -> GoogleAuthSession? {
        guard let clientID = state?.settings.googleClientID, !clientID.isEmpty else { return nil }
        let client = GoogleOAuthClient(clientID: clientID, clientSecret: vault.clientSecret, http: http)
        return GoogleAuthSession(client: client, store: vault)
    }

    private func startLoop() {
        stop()
        for kind in SyncKind.allCases {
            loops[kind] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let delay = await self.syncOnce(kind)
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 5) * 1_000_000_000))
                }
            }
        }
    }

    private func interval(for kind: SyncKind) -> TimeInterval {
        switch kind {
        case .chat: return 5
        case .gmail: return 30
        case .calendar: return state?.settings.googleSyncInterval ?? 180
        case .tasks: return 60
        }
    }

    private func isEnabled(_ kind: SyncKind) -> Bool {
        switch kind {
        case .chat: return modules.googleChat
        case .gmail: return modules.gmail
        case .calendar: return modules.googleCalendar
        case .tasks: return modules.googleTasks
        }
    }

    // MARK: - Sign-in

    var requiredScopes: Set<String> {
        var scopes: Set<String> = []
        if modules.gmail { scopes.formUnion(GoogleScope.gmailRead) }
        if modules.googleChat { scopes.formUnion(GoogleScope.chatRead) }
        if modules.googleCalendar { scopes.insert(GoogleScope.calendarEventsReadonly) }
        if modules.googleTasks { scopes.insert(GoogleScope.tasksReadonly) }
        return scopes.isEmpty ? GoogleScope.gmailRead : scopes
    }

    func saveCredentials(clientID: String, clientSecret: String) {
        guard let coordinator else { return }
        var settings = coordinator.state.settings
        settings.googleClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty { try? vault.setClientSecret(secret) }
        coordinator.updateSettings(settings)
        session = makeSession()
        coordinator.settingsWindow.lastError = "Identifiants OAuth enregistrés."
    }

    /// Opens Google's consent page in the default browser and waits for the loopback redirect.
    func connect(extraScopes: Set<String> = []) {
        guard let coordinator else { return }
        if session == nil { session = makeSession() }
        guard let session, let clientID = state?.settings.googleClientID, !clientID.isEmpty else {
            coordinator.settingsWindow.lastError = "Renseignez d’abord le Client ID OAuth (voir docs/GOOGLE_OAUTH.md)."
            coordinator.openSettings()
            return
        }
        signInTask?.cancel()
        let client = GoogleOAuthClient(clientID: clientID, clientSecret: vault.clientSecret, http: http)
        let scopes = requiredScopes.union(extraScopes)
        setStatuses(.connecting)
        signInTask = Task { [weak self] in
            do {
                let receiver = try LoopbackReceiver()
                let verifier = PKCE.makeVerifier()
                let expectedState = PKCE.makeState()
                let firstConsent = await !session.isConnected
                let url = client.authorizationURL(
                    scopes: scopes, redirectURI: receiver.redirectURI, state: expectedState,
                    codeChallenge: PKCE.challenge(for: verifier), firstConsent: firstConsent)
                NSWorkspace.shared.open(url)
                let query = try await receiver.waitForCallback(timeout: 300, expectedState: expectedState)
                let code = try GoogleOAuthClient.code(fromRedirect: query, expectedState: expectedState)
                let tokens = try await client.exchange(code: code, verifier: verifier, redirectURI: receiver.redirectURI)
                try await session.install(tokens)
                guard let self else { return }
                self.coordinator?.settingsWindow.lastError = nil
                self.restart()
            } catch {
                guard let self else { return }
                let message: String
                switch error as? OAuthError {
                case .accessDenied?: message = "Autorisation refusée sur la page Google."
                case .timeout?: message = "Délai de connexion dépassé."
                case .stateMismatch?: message = "Réponse OAuth invalide (state)."
                default: message = "Connexion Google impossible."
                }
                self.coordinator?.settingsWindow.lastError = message
                await self.refreshStatuses()
            }
        }
    }

    func disconnect() {
        stop()
        let session = self.session
        Task { [weak self] in
            await session?.signOut()
            guard let self, let state = self.state else { return }
            state.mail = []
            state.unreadCount = nil
            state.chatUnread = []
            self.chatMonitor = nil
            state.googleAccount = nil
            self.coordinator?.googleEvents = []
            self.coordinator?.mergeEvents()
            self.coordinator?.setGoogleTasks([])
            self.gmailMonitor = nil
            self.setStatuses(.disconnected)
        }
    }

    private func setStatuses(_ status: ConnectorStatus) {
        state?.gmailStatus = modules.gmail ? status : .disconnected
        state?.chatStatus = modules.googleChat ? status : .disconnected
    }

    private func refreshStatuses() async {
        guard let session, await session.isConnected else {
            setStatuses(.disconnected)
            return
        }
        state?.gmailCanModify = await session.grants(GoogleScope.gmailModify)
    }

    // MARK: - Sync

    /// One sync round for a connector; returns the delay before the next one.
    private func syncOnce(_ kind: SyncKind) async -> TimeInterval {
        let interval = interval(for: kind)
        guard isEnabled(kind) else { return max(interval, 60) }
        guard let session, await session.isConnected else {
            setStatuses(.disconnected)
            return interval
        }
        guard bucket.tryConsume(1, now: Date()) else { return bucket.waitTime(for: 1, now: Date()) + 1 }
        if kind == .calendar { await refreshStatuses() }
        let api = GoogleAPI(auth: session, http: http)
        var failure: GoogleAPIError?
        do {
            switch kind {
            case .gmail:
                try await syncGmail(api: api)
            case .chat:
                try await syncChat(api: api)
            case .calendar:
                let now = Date()
                coordinator?.googleEvents = try await GoogleCalendarService(api: api).upcomingEvents(from: now, to: now.addingTimeInterval(24 * 3600))
                coordinator?.mergeEvents()
            case .tasks:
                coordinator?.setGoogleTasks(try await GoogleTasksService(api: api).openTasks())
            }
        } catch {
            failure = handle(error, attempt: attempts[kind] ?? 0) { status in
                switch kind {
                case .gmail: self.state?.gmailStatus = status
                case .chat: self.state?.chatStatus = status
                case .calendar, .tasks: break
                }
            }
        }

        guard let failure, failure.isRetryable else {
            attempts[kind] = 0
            return interval
        }
        if case let .rateLimited(retryAfter?) = failure { return max(retryAfter, interval) }
        let attempt = (attempts[kind] ?? 0) + 1
        attempts[kind] = attempt
        return backoff.delay(attempt: attempt)
    }

    /// Maps an error to a connector status; returns retryable errors for backoff.
    private func handle(_ error: Error, attempt: Int, update: (ConnectorStatus) -> Void) -> GoogleAPIError? {
        let apiError = error as? GoogleAPIError ?? .network("unknown")
        switch apiError {
        case .reauthorizationRequired, .notConnected:
            update(.needsReauthorization)
        case let .unsupported(reason):
            update(.unsupported(reason: reason))
        case .insufficientScope:
            update(.needsReauthorization)
        default:
            let retryAt = Date().addingTimeInterval(backoff.delay(attempt: attempt + 1, random: 0.5))
            update(.error(message: apiError.message, retryAt: apiError.isRetryable ? retryAt : nil))
        }
        return apiError.isRetryable ? apiError : nil
    }

    private func syncGmail(api: GoogleAPI) async throws {
        let monitor = gmailMonitor ?? GmailMonitor(service: GmailService(api: api))
        gmailMonitor = monitor
        let snapshot = try await monitor.sync()
        guard let state else { return }
        state.gmailStatus = .connected(account: snapshot.account)
        state.googleAccount = snapshot.account
        if state.unreadCount != snapshot.unreadCount {
            state.unreadCount = snapshot.unreadCount
            coordinator?.refreshLiveActivity()
        }
        if state.mail != snapshot.messages { state.mail = snapshot.messages }
        let fresh = snapshot.messages.filter { snapshot.newMessageIDs.contains($0.id) }
        let now = Date()
        if fresh.count == 1, let mail = fresh.first {
            coordinator?.post(ActivityItem(
                source: .mail, priority: .p2, coalescingKey: "mail", title: mail.senderName, subtitle: mail.subject,
                symbol: "envelope", reference: mail.id, createdAt: now, expiresAt: now.addingTimeInterval(8)))
        } else if fresh.count > 1 {
            coordinator?.post(ActivityItem(
                source: .mail, priority: .p2, coalescingKey: "mail", title: "\(fresh.count) nouveaux e-mails",
                subtitle: "\(fresh.count) nouveaux", symbol: "envelope", createdAt: now, expiresAt: now.addingTimeInterval(6)))
        }
    }

    private func syncChat(api: GoogleAPI) async throws {
        let monitor = chatMonitor ?? ChatUnreadMonitor(service: GoogleChatService(api: api), people: GooglePeopleService(api: api))
        chatMonitor = monitor
        let snapshot = try await monitor.sync()
        guard let state else { return }
        state.chatStatus = .connected(account: state.googleAccount)
        if state.chatUnread != snapshot.unread {
            state.chatUnread = snapshot.unread
            coordinator?.refreshLiveActivity()
        }
        let now = Date()
        for item in snapshot.fresh.prefix(2) {
            coordinator?.post(ActivityItem(
                source: .chat, priority: .p2, coalescingKey: "chat:\(item.id)", title: item.title,
                subtitle: Redactor.truncate(item.preview, limit: 80), symbol: "bubble.left", reference: item.id,
                createdAt: now, expiresAt: now.addingTimeInterval(8)))
        }
    }

    // MARK: - Actions

    /// Opening a message in Gmail marks it read: drop it now instead of waiting for the next sync.
    func noteOpened(_ mail: MailSummary) {
        let monitor = gmailMonitor
        Task { await monitor?.remove(messageID: mail.id) }
        dropFromInbox(mail)
    }

    private func dropFromInbox(_ mail: MailSummary) {
        guard let state, state.mail.contains(where: { $0.id == mail.id }) else { return }
        state.mail.removeAll { $0.id == mail.id }
        state.unreadCount = state.unreadCount.map { max(0, $0 - 1) }
        coordinator?.refreshLiveActivity()
    }

    /// Completes a Google task; asks for the `tasks` scope the first time (progressive consent).
    func completeTask(id: String) {
        guard let session else { return }
        let http = self.http
        Task { [weak self] in
            guard await session.grants(GoogleScope.tasks) else {
                self?.connect(extraScopes: [GoogleScope.tasks])
                return
            }
            do {
                try await GoogleTasksService(api: GoogleAPI(auth: session, http: http)).complete(reminderID: id)
                self?.coordinator?.dropGoogleTask(id: id)
            } catch {
                self?.coordinator?.showError((error as? GoogleAPIError)?.message ?? "Impossible de terminer la tâche.")
            }
        }
    }

    func markRead(_ mail: MailSummary) {
        modify(mail) { try await $0.markRead(id: mail.id) }
    }

    func archive(_ mail: MailSummary) {
        modify(mail) { try await $0.archive(id: mail.id) }
    }

    private func modify(_ mail: MailSummary, _ operation: @escaping @Sendable (GmailService) async throws -> Void) {
        guard let session else { return }
        let http = self.http
        Task { [weak self] in
            guard await session.grants(GoogleScope.gmailModify) else {
                // Progressive consent: ask for gmail.modify only when first needed.
                self?.connect(extraScopes: [GoogleScope.gmailModify])
                return
            }
            do {
                try await operation(GmailService(api: GoogleAPI(auth: session, http: http)))
                await self?.gmailMonitor?.remove(messageID: mail.id)
                self?.dropFromInbox(mail)
            } catch {
                self?.coordinator?.showError((error as? GoogleAPIError)?.message ?? "Action Gmail impossible.")
            }
        }
    }

    /// Opening a conversation in Google Chat reads it: drop it now instead of waiting for the
    /// next sync (it comes back only with new activity).
    func noteOpened(_ chat: ChatUnread) {
        let monitor = chatMonitor
        Task { await monitor?.markSeen(spaceID: chat.id) }
        guard let state, state.chatUnread.contains(where: { $0.id == chat.id }) else { return }
        state.chatUnread.removeAll { $0.id == chat.id }
        coordinator?.refreshLiveActivity()
    }

    func refreshNow() {
        guard anyEnabled else { return }
        attempts.removeAll()
        startLoop()
    }
}

// MARK: - EspazioActions / SettingsActions (Google)

extension AppCoordinator {
    func connectGoogle() { google?.connect() }
    func disconnectGoogle() { google?.disconnect() }
    func saveGoogleCredentials(clientID: String, clientSecret: String) {
        google?.saveCredentials(clientID: clientID, clientSecret: clientSecret)
    }
    func refreshGoogle() { google?.refreshNow() }

    func openMail(_ mail: MailSummary) {
        NSWorkspace.shared.open(GmailService.webURL(threadID: mail.threadID))
        google?.noteOpened(mail)
        display.collapseAll()
    }

    func markMailRead(_ mail: MailSummary) { google?.markRead(mail) }
    func archiveMail(_ mail: MailSummary) { google?.archive(mail) }

    func openChat(_ chat: ChatUnread) {
        NSWorkspace.shared.open(GoogleChatService.webURL(spaceID: chat.id))
        google?.noteOpened(chat)
        display.collapseAll()
    }

}
