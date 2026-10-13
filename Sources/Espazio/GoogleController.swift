import AppKit
import EspazioCore
import EspazioUI
import GoogleProvider

/// Google connectors: OAuth (PKCE + loopback, system browser — no WebView), moderate sync loop
/// with configurable interval, exponential backoff, rate limiting and progressive consent.
@MainActor
final class GoogleController {
    private weak var coordinator: AppCoordinator?
    private let http = URLSessionHTTPClient()
    private let tokenStore = KeychainTokenStore()
    private let secretItem = KeychainItem(service: "app.espazio.google", account: "client-secret")
    private var session: GoogleAuthSession?
    private var gmailMonitor: GmailMonitor?
    private var loopTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var attempt = 0
    private var bucket = TokenBucket(capacity: 20, refillRate: 0.2, now: Date())
    private let backoff = ExponentialBackoff(base: 30, maximum: 30 * 60, jitter: 0.2)
    private var chatLastActive: [String: Date] = [:]
    private var chatPrimed = false
    private var paused = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    private var state: EspazioState? { coordinator?.state }
    private var modules: ModuleSettings { state?.settings.modules ?? ModuleSettings() }
    private var anyEnabled: Bool { modules.gmail || modules.googleChat || modules.googleCalendar }

    // MARK: - Lifecycle

    func start() {
        session = makeSession()
        Task { await refreshStatuses() }
        guard anyEnabled, !paused else { return }
        startLoop()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func restart() {
        stop()
        attempt = 0
        chatPrimed = false
        chatLastActive.removeAll()
        Task { await gmailMonitor?.reset() }
        gmailMonitor = nil
        if !modules.googleCalendar {
            coordinator?.googleEvents = []
            coordinator?.mergeEvents()
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
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startLoop()
        }
    }

    private func makeSession() -> GoogleAuthSession? {
        guard let clientID = state?.settings.googleClientID, !clientID.isEmpty else { return nil }
        let secret = secretItem.read().map { String(decoding: $0, as: UTF8.self) }
        let client = GoogleOAuthClient(clientID: clientID, clientSecret: secret, http: http)
        return GoogleAuthSession(client: client, store: tokenStore)
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.syncOnce()
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 30) * 1_000_000_000))
            }
        }
    }

    // MARK: - Sign-in

    var requiredScopes: Set<String> {
        var scopes: Set<String> = []
        if modules.gmail { scopes.formUnion(GoogleScope.gmailRead) }
        if modules.googleChat { scopes.formUnion(GoogleScope.chatRead.union([GoogleScope.chatMessagesCreate])) }
        if modules.googleCalendar { scopes.insert(GoogleScope.calendarEventsReadonly) }
        return scopes.isEmpty ? GoogleScope.gmailRead : scopes
    }

    func saveCredentials(clientID: String, clientSecret: String) {
        guard let coordinator else { return }
        var settings = coordinator.state.settings
        settings.googleClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty { try? secretItem.write(Data(secret.utf8)) }
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
        let secret = secretItem.read().map { String(decoding: $0, as: UTF8.self) }
        let client = GoogleOAuthClient(clientID: clientID, clientSecret: secret, http: http)
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
            state.chatSpaces = []
            state.chatMessages = [:]
            state.googleAccount = nil
            self.coordinator?.googleEvents = []
            self.coordinator?.mergeEvents()
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
        state?.chatCanReply = await session.grants(GoogleScope.chatMessagesCreate)
    }

    // MARK: - Sync

    /// One sync round; returns the delay before the next one.
    private func syncOnce() async -> TimeInterval {
        let interval = state?.settings.googleSyncInterval ?? 180
        guard let session, await session.isConnected, anyEnabled else {
            setStatuses(.disconnected)
            return interval
        }
        guard bucket.tryConsume(5, now: Date()) else { return bucket.waitTime(for: 5, now: Date()) + 1 }
        await refreshStatuses()
        let api = GoogleAPI(auth: session, http: http)
        var worst: GoogleAPIError?

        if modules.gmail {
            do {
                try await syncGmail(api: api)
            } catch {
                worst = handle(error, update: { self.state?.gmailStatus = $0 })
            }
        }
        if modules.googleChat {
            do {
                try await syncChat(api: api)
            } catch {
                worst = handle(error, update: { self.state?.chatStatus = $0 }) ?? worst
            }
        }
        if modules.googleCalendar {
            do {
                let now = Date()
                coordinator?.googleEvents = try await GoogleCalendarService(api: api).upcomingEvents(from: now, to: now.addingTimeInterval(24 * 3600))
                coordinator?.mergeEvents()
            } catch {
                worst = handle(error, update: { _ in }) ?? worst
            }
        }

        guard let worst, worst.isRetryable else {
            attempt = 0
            return interval
        }
        if case let .rateLimited(retryAfter?) = worst { return max(retryAfter, interval) }
        attempt += 1
        return backoff.delay(attempt: attempt)
    }

    /// Maps an error to a connector status; returns retryable errors for backoff.
    private func handle(_ error: Error, update: (ConnectorStatus) -> Void) -> GoogleAPIError? {
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
                symbol: "envelope", reference: mail.id, createdAt: now, expiresAt: now.addingTimeInterval(6)))
        } else if fresh.count > 1 {
            coordinator?.post(ActivityItem(
                source: .mail, priority: .p2, coalescingKey: "mail", title: "\(fresh.count) nouveaux e-mails",
                subtitle: "\(fresh.count) nouveaux", symbol: "envelope", createdAt: now, expiresAt: now.addingTimeInterval(6)))
        }
    }

    private func syncChat(api: GoogleAPI) async throws {
        let service = GoogleChatService(api: api)
        let spaces = try await service.listSpaces()
        guard let state else { return }
        state.chatStatus = .connected(account: state.googleAccount)
        let ordered = spaces.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        state.chatSpaces = ordered.map(\.space)
        defer { chatPrimed = true }
        // Fetch messages only for spaces whose activity advanced (bounded to 3 per round).
        var changed: [GoogleChatService.SpaceActivity] = []
        for activity in ordered {
            guard let active = activity.lastActive else { continue }
            if let previous = chatLastActive[activity.space.id], active > previous { changed.append(activity) }
            chatLastActive[activity.space.id] = active
        }
        guard chatPrimed else { return }
        for activity in changed.prefix(3) {
            let messages = try await service.listMessages(spaceID: activity.space.id, limit: 10)
            storeMessages(messages, spaceID: activity.space.id)
            if let last = messages.last {
                let now = Date()
                coordinator?.post(ActivityItem(
                    source: .chat, priority: .p2, coalescingKey: "chat:\(activity.space.id)", title: last.sender,
                    subtitle: Redactor.truncate(last.text, limit: 80), symbol: "bubble.left", reference: activity.space.id,
                    createdAt: now, expiresAt: now.addingTimeInterval(6)))
            }
        }
    }

    private func storeMessages(_ messages: [ChatMessage], spaceID: String) {
        guard let state else { return }
        state.chatMessages[spaceID] = messages
        if state.chatMessages.count > 8 {
            let keep = Set(state.chatSpaces.prefix(8).map(\.id)).union([spaceID])
            state.chatMessages = state.chatMessages.filter { keep.contains($0.key) }
        }
    }

    // MARK: - Actions

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
                guard let state = self?.state else { return }
                state.mail.removeAll { $0.id == mail.id }
                state.unreadCount = state.unreadCount.map { max(0, $0 - 1) }
            } catch {
                self?.coordinator?.showError((error as? GoogleAPIError)?.message ?? "Action Gmail impossible.")
            }
        }
    }

    func loadMessages(spaceID: String) {
        guard let session else { return }
        let http = self.http
        Task { [weak self] in
            do {
                let messages = try await GoogleChatService(api: GoogleAPI(auth: session, http: http)).listMessages(spaceID: spaceID)
                self?.storeMessages(messages, spaceID: spaceID)
            } catch {
                self?.coordinator?.showError((error as? GoogleAPIError)?.message ?? "Messages indisponibles.")
            }
        }
    }

    func send(spaceID: String, text: String) {
        guard let session else { return }
        let http = self.http
        Task { [weak self] in
            guard await session.grants(GoogleScope.chatMessagesCreate) else {
                self?.connect(extraScopes: [GoogleScope.chatMessagesCreate])
                return
            }
            do {
                let message = try await GoogleChatService(api: GoogleAPI(auth: session, http: http)).send(spaceID: spaceID, text: text)
                guard let self, let state = self.state else { return }
                self.storeMessages((state.chatMessages[spaceID] ?? []) + [message], spaceID: spaceID)
            } catch {
                self?.coordinator?.showError((error as? GoogleAPIError)?.message ?? "Envoi impossible.")
            }
        }
    }

    func refreshNow() {
        guard anyEnabled else { return }
        attempt = 0
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
        display.collapseAll()
    }

    func markMailRead(_ mail: MailSummary) { google?.markRead(mail) }
    func archiveMail(_ mail: MailSummary) { google?.archive(mail) }

    func openChatSpace(_ space: ChatSpace) {
        NSWorkspace.shared.open(GoogleChatService.webURL(spaceID: space.id))
        display.collapseAll()
    }

    func loadChatMessages(spaceID: String) { google?.loadMessages(spaceID: spaceID) }
    func sendChatReply(spaceID: String, text: String) { google?.send(spaceID: spaceID, text: text) }
}
