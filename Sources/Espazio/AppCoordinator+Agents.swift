import AgentIntegrations
import AppKit
import EspazioBridge
import EspazioCore
import EspazioUI

/// AI Activity Center wiring: local bridge for Claude Code hooks and Codex `notify`,
/// `codex app-server` sessions started from Espazio, ChatGPT Desktop state (best effort).
extension AppCoordinator {
    static let chatGPTBundleID = "com.openai.chat"

    var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/espazio-hook").path
    }

    func startAgents() {
        observeApprovals()
        configureBridge()
        configureChatGPT()
        state.claudeHooksInstalled = ClaudeHookInstaller.isInstalled(in: try? Data(contentsOf: ClaudeHookInstaller.defaultSettingsURL()))
    }

    /// The bridge only runs when an agent integration needs it.
    func configureBridge() {
        let modules = state.settings.modules
        let needed = modules.claudeCode || modules.codex
        if needed, bridge == nil {
            let server = BridgeServer { [weak self] request, peer in
                guard let self else { return BridgeReply(id: request.id, status: .passThrough) }
                return await self.handleBridge(request, peer: peer)
            }
            do {
                try server.start()
                bridge = server
            } catch {
                showError("Bridge local indisponible : une autre instance d’Espazio est peut-être ouverte.")
            }
        } else if !needed, let bridge {
            bridge.stop()
            self.bridge = nil
            Task { await approvals.cancelAll(provider: .claudeCode, reason: .disconnected) }
        }
        if !modules.codex {
            codexTransport?.close()
        }
    }

    /// Runs off the main actor; touches UI state only through `MainActor.run`.
    nonisolated func handleBridge(_ request: BridgeRequest, peer: BridgePeer) async -> BridgeReply {
        switch request.kind {
        case "claude.hook":
            return await handleClaudeHook(request)
        case "codex.notify":
            let events = CodexNotify.events(fromPayload: request.body)
            await MainActor.run {
                guard self.state.settings.modules.codex else { return }
                events.forEach { self.apply($0) }
            }
            return BridgeReply(id: request.id, status: .accepted)
        default:
            return BridgeReply(id: request.id, status: .error, body: "unknown kind")
        }
    }

    private nonisolated func handleClaudeHook(_ request: BridgeRequest) async -> BridgeReply {
        guard let input = try? ClaudeHookInput.decode(request.body) else {
            return BridgeReply(id: request.id, status: .error, body: "invalid input")
        }
        let (enabled, timeout) = await MainActor.run { (state.settings.modules.claudeCode, state.settings.agentRequestTimeout) }
        guard enabled else { return BridgeReply(id: request.id, status: .passThrough) }
        let hint = request.hints[HostApplication.hintKey] ?? request.hints["__CFBundleIdentifier"] ?? request.hints["TERM_PROGRAM"]
        let event = ClaudeHookMapper.agentEvent(for: input, clientHint: hint)
        await MainActor.run {
            if let event { self.apply(event) }
            if self.sessionStore.noteClientHint(sessionID: input.sessionID, hint: hint) { self.publishSessions() }
        }
        guard input.hookEventName == ClaudeHookEvent.permissionRequest.rawValue else {
            return BridgeReply(id: request.id, status: .accepted)
        }
        guard let approval = ClaudeHookMapper.approvalRequest(for: input, fallbackID: request.id, now: Date(), timeout: timeout) else {
            // Tools requiring Claude's own UI (AskUserQuestion…): let Claude Code handle them.
            return BridgeReply(id: request.id, status: .passThrough)
        }
        await MainActor.run {
            self.sessionStore.noteMetadata(sessionID: input.sessionID, provider: .claudeCode, projectPath: input.cwd, control: .approvals, now: Date())
            self.publishSessions()
        }
        let approvals = self.approvals
        // The hook may already be gone (Claude interrupted during the hops above).
        guard !Task.isCancelled else { return BridgeReply(id: request.id, status: .passThrough) }
        let response = await withTaskCancellationHandler {
            await approvals.submit(approval)
        } onCancel: {
            // The hook process went away (Claude interrupted): withdraw, never approve.
            Task { await approvals.cancel(requestID: approval.id, reason: .disconnected) }
        }
        await MainActor.run { self.apply(.activity(sessionID: input.sessionID, provider: .claudeCode, message: nil)) }
        return BridgeReply(id: request.id, status: .ok, body: ClaudeHookMapper.permissionOutput(for: response))
    }

    func apply(_ event: AgentEvent) {
        let now = Date()
        sessionStore.apply(event, now: now)
        sessionStore.prune(olderThan: 6 * 3600, now: now)
        publishSessions()
        let name = sessionStore.sessions[event.sessionID]?.projectName ?? event.provider.displayName
        switch event {
        case let .waiting(id, provider, _) where !state.pendingRequests.contains(where: { $0.sessionID == id }):
            post(ActivityItem(source: .agents, priority: .p2, coalescingKey: "agent:\(id)", title: "\(provider.displayName) attend",
                              subtitle: name, symbol: "hand.raised", reference: id, createdAt: now, expiresAt: now.addingTimeInterval(5)))
        case let .turnCompleted(id, provider, _):
            post(ActivityItem(source: .agents, priority: .p3, coalescingKey: "agent:\(id)", title: "Terminé", subtitle: "\(provider.displayName) · \(name)",
                              symbol: "checkmark.circle", reference: id, createdAt: now, expiresAt: now.addingTimeInterval(4)))
        case let .turnFailed(id, provider, _):
            post(ActivityItem(source: .agents, priority: .p2, coalescingKey: "agent:\(id)", title: "Échec", subtitle: "\(provider.displayName) · \(name)",
                              symbol: "xmark.octagon", reference: id, createdAt: now, expiresAt: now.addingTimeInterval(6)))
        case let .sessionEnded(id, _):
            dismissActivity(key: "agent:\(id)")
            Task { [approvals] in await approvals.cancelAll(sessionID: id, reason: .cancelled) }
        default:
            break
        }
    }

    func publishSessions() {
        state.sessions = sessionStore.ordered
        refreshLiveActivity()
    }

    // MARK: - Actions

    func resolve(_ request: AgentRequest, response: AgentResponse) {
        let approvals = self.approvals
        Task {
            let result = await approvals.resolve(requestID: request.id, sessionID: request.sessionID, response: response)
            if result == .sessionMismatch || result == .invalidResponse {
                showError("Décision refusée : la demande ne correspond plus à cette session.")
            }
        }
    }

    func openSession(_ session: AgentSession) {
        if session.provider == .chatGPT {
            openChatGPT()
            return
        }
        if let hint = session.clientHint, let url = Self.applicationURL(forHint: hint) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let path = session.projectPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        display.collapseAll()
    }

    /// Maps the host application's bundle path, `__CFBundleIdentifier` or `TERM_PROGRAM` to an
    /// installed application.
    static func applicationURL(forHint hint: String) -> URL? {
        if hint.hasPrefix("/") {
            // Bundle path found by espazio-hook in its process ancestry: only a real application.
            let url = URL(fileURLWithPath: hint, isDirectory: true)
            guard url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier != nil else { return nil }
            return url
        }
        let known: [String: String] = [
            "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2", "vscode": "com.microsoft.VSCode",
            "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm",
            "zed": "dev.zed.Zed", "cursor": "com.todesktop.230313mzl4w4u92",
        ]
        let bundleID = known[hint] ?? hint
        guard bundleID.contains(".") else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func setClaudeHooksInstalled(_ installed: Bool) {
        do {
            try ClaudeHookInstaller.apply(install: installed, helperPath: helperPath)
            state.claudeHooksInstalled = installed
            settingsWindow.lastError = installed
                ? "Hooks installés. Une sauvegarde de settings.json a été créée (settings.json.espazio-backup)."
                : "Hooks retirés."
        } catch ClaudeHookInstaller.InstallError.unreadableSettingsFile {
            settingsWindow.lastError = "~/.claude/settings.json est illisible : aucune modification."
        } catch ClaudeHookInstaller.InstallError.helperNotFound {
            settingsWindow.lastError = "Assistant espazio-hook introuvable : lancez Espazio depuis l’application assemblée (scripts/build-app.sh)."
        } catch {
            settingsWindow.lastError = "Impossible de modifier ~/.claude/settings.json (fichier JSON invalide ?)."
        }
    }

    func installCodexNotify() {
        let url = CodexNotify.defaultConfigURL().resolvingSymlinksInPath()
        let original: Data?
        do {
            original = try ConfigFile.read(url)
        } catch {
            settingsWindow.lastError = "~/.codex/config.toml est illisible : aucune modification."
            return
        }
        let existing = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        switch CodexNotify.installing(into: existing, helperPath: helperPath) {
        case let .installed(text):
            do {
                try ConfigFile.write(Data(text.utf8), to: url, original: original)
                settingsWindow.lastError = "Suivi Codex CLI activé (~/.codex/config.toml)."
            } catch {
                settingsWindow.lastError = "Impossible d’écrire ~/.codex/config.toml."
            }
        case .alreadyInstalled:
            settingsWindow.lastError = "Le suivi Codex CLI est déjà configuré."
        case .conflict:
            settingsWindow.lastError = "Un programme « notify » est déjà configuré dans ~/.codex/config.toml : Espazio ne le remplace pas."
        }
    }

    // MARK: - Codex app-server sessions

    func startCodexSession() {
        guard state.settings.modules.codex else { return }
        guard let executable = CodexLocator.locate() else {
            showError("Codex CLI introuvable (installez « codex » puis réessayez).")
            return
        }
        display.collapseAll()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choisir le projet"
        panel.message = "Dossier dans lequel Codex travaillera"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Nouvelle tâche Codex"
        alert.informativeText = "Décrivez la tâche. Les commandes et modifications demanderont votre autorisation dans la notch."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Ex. : corrige les tests qui échouent"
        alert.accessoryView = field
        alert.addButton(withTitle: "Lancer")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        Task {
            do {
                let client = try await ensureCodexClient(executable: executable)
                let thread = try await client.startThread(cwd: folder.path)
                try await client.startTurn(threadID: thread, text: prompt)
                scheduleCodexIdleShutdown()
            } catch {
                showError("Impossible de démarrer Codex.")
                state.codexStatus = .error(message: "codex app-server n’a pas répondu.", retryAt: nil)
            }
        }
    }

    private func ensureCodexClient(executable: URL) async throws -> CodexAppServerClient {
        if let codexClient, let codexTransport, codexTransport.isRunning, await !codexClient.isClosed {
            return codexClient
        }
        let transport = try ProcessLineTransport(
            executable: executable, arguments: ["app-server"], environment: CodexLocator.childEnvironment())
        let client = CodexAppServerClient(
            transport: transport, approvals: approvals, decisionTimeout: state.settings.agentRequestTimeout
        ) { [weak self] event in
            Task { @MainActor in
                self?.apply(event)
                self?.scheduleCodexIdleShutdown()
            }
        }
        codexTransport = transport
        codexClient = client
        state.codexStatus = .connecting
        try await client.start(clientVersion: Self.version)
        state.codexStatus = .connected(account: nil)
        return client
    }

    /// The app-server process only lives while it is useful: stopped after 15 min without
    /// activity and without pending requests.
    func scheduleCodexIdleShutdown() {
        codexIdleTask?.cancel()
        codexIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let busy = self.state.pendingRequests.contains { $0.provider == .codex }
                || self.state.sessions.contains { $0.provider == .codex && $0.control == .full && $0.state == .active }
            if busy {
                self.scheduleCodexIdleShutdown()
            } else {
                self.codexTransport?.close()
                self.codexTransport = nil
                self.codexClient = nil
                self.state.codexStatus = .disconnected
            }
        }
    }

    // MARK: - ChatGPT Desktop (best effort: running state + open)

    func configureChatGPT() {
        chatGPTObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        chatGPTObservers.removeAll()
        guard state.settings.modules.chatGPT else {
            state.chatGPTRunning = false
            return
        }
        let update: @MainActor () -> Void = { [weak self] in
            self?.state.chatGPTRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chatGPTBundleID).isEmpty
        }
        update()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            chatGPTObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    if bundleID == Self.chatGPTBundleID { update() }
                }
            })
        }
    }

    func openChatGPT() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chatGPTBundleID) else {
            showError("ChatGPT Desktop n’est pas installé.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        display.collapseAll()
    }
}
