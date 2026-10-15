import EspazioCore
import SwiftUI

/// Settings-specific intents.
@MainActor
public protocol SettingsActions: AnyObject {
    func updateSettings(_ settings: EspazioSettings)
    func setClaudeHooksInstalled(_ installed: Bool)
    func installCodexNotify()
    func saveGoogleCredentials(clientID: String, clientSecret: String)
    func connectGoogle()
    func disconnectGoogle()
    func requestCalendarAccess()
    func requestRemindersAccess()
    func openPrivacySettings(_ pane: String)
    func refreshDiagnostics()
    func revealAuditLog()
    func setLaunchAtLogin(_ enabled: Bool)
    func checkForUpdates()
    func setAutomaticUpdateChecks(_ enabled: Bool)
    func showWelcome()
}

public struct SettingsView: View {
    let state: EspazioState
    let actions: SettingsActions
    let lastError: String?

    public init(state: EspazioState, actions: SettingsActions, lastError: String? = nil) {
        self.state = state
        self.actions = actions
        self.lastError = lastError
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EspazioSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = state.settings
                copy[keyPath: keyPath] = newValue
                actions.updateSettings(copy)
            })
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("Général", systemImage: "gearshape") }
            modules.tabItem { Label("Modules", systemImage: "square.grid.2x2") }
            agents.tabItem { Label("Agents IA", systemImage: "sparkles") }
            google.tabItem { Label("Google", systemImage: "envelope") }
            diagnostics.tabItem { Label("Diagnostic", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 470)
    }

    // MARK: - Tabs

    private var general: some View {
        Form {
            Section("Démarrage") {
                Toggle("Ouvrir Espazio à l’ouverture de session", isOn: Binding(
                    get: { state.launchAtLogin }, set: { actions.setLaunchAtLogin($0) }))
                Button("Revoir l’écran de bienvenue") { actions.showWelcome() }
            }
            Section("Affichage") {
                Picker("Écrans", selection: binding(\.displayMode)) {
                    Text("Écran principal").tag(DisplayMode.mainOnly)
                    Text("Tous les écrans").tag(DisplayMode.allScreens)
                    Text("Écran actif").tag(DisplayMode.activeScreen)
                }
                Toggle("Masquer au-dessus des apps en plein écran", isOn: binding(\.hideInFullScreen))
                Toggle("Ouvrir au survol", isOn: binding(\.expandOnHover))
                if state.settings.expandOnHover {
                    Slider(value: binding(\.hoverDelay), in: 0...1, step: 0.05) {
                        Text("Délai de survol : \(String(format: "%.2f", state.settings.hoverDelay)) s")
                    }
                }
            }
            Section {
                Toggle("Média en cours de lecture", isOn: binding(\.live.media))
                Toggle("Garder le média affiché en pause", isOn: binding(\.live.mediaWhenPaused))
                    .disabled(!state.settings.live.media)
                Toggle("Compte à rebours de la prochaine réunion", isOn: binding(\.live.nextEvent))
                if state.settings.live.nextEvent {
                    Stepper(value: binding(\.live.eventLeadMinutes), in: 5...240, step: 5) {
                        Text("À partir de \(state.settings.live.eventLeadMinutes) min avant le début")
                    }
                }
                Toggle("Agents IA actifs ou en attente", isOn: binding(\.live.agents))
                Toggle("Badge des e-mails non lus", isOn: binding(\.live.mailBadge))
                    .disabled(!state.settings.modules.gmail)
                Toggle("Badge des nouveaux messages Google Chat", isOn: binding(\.live.chatBadge))
                    .disabled(!state.settings.modules.googleChat)
                Toggle("Badge des iMessages non lus", isOn: binding(\.live.messagesBadge))
                    .disabled(!state.settings.modules.iMessage)
            } header: {
                Text("Affichage continu (notch au repos)")
            } footer: {
                Text("Une seule information à la fois, par priorité : agent en attente, réunion proche, média, agents actifs, e-mails, Chat. Les badges d’e-mails et de Chat restent visibles à côté des autres informations. Les notifications ponctuelles passent devant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Concentration") {
                Picker("Mode", selection: binding(\.focusMode)) {
                    Text("Normal").tag(FocusMode.normal)
                    Text("Concentré (P0–P1)").tag(FocusMode.focused)
                    Text("Silencieux").tag(FocusMode.silent)
                }
                Toggle("Limiter les interruptions en réunion, en plein écran ou pendant une présentation (écran recopié)", isOn: binding(\.contextualFocus))
                Text("L’état des modes Concentration de macOS n’est pas exposé par une API publique adaptée : Espazio utilise son propre mode, explicite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Raccourcis") {
                LabeledContent("Actions rapides") {
                    ShortcutRecorder(shortcut: state.settings.quickActionsShortcut, defaultShortcut: .defaultQuickActions) { new in
                        var copy = state.settings
                        copy.quickActionsShortcut = new
                        actions.updateSettings(copy)
                    }
                }
                LabeledContent("Ouvrir / fermer la notch") {
                    ShortcutRecorder(shortcut: state.settings.toggleNotchShortcut, defaultShortcut: .defaultToggleNotch) { new in
                        var copy = state.settings
                        copy.toggleNotchShortcut = new
                        actions.updateSettings(copy)
                    }
                }
            }
            Section("Mises à jour") {
                if state.updatesConfigured {
                    Toggle("Rechercher automatiquement les mises à jour", isOn: Binding(
                        get: { state.automaticUpdateChecks }, set: { actions.setAutomaticUpdateChecks($0) }))
                    Button("Rechercher maintenant") { actions.checkForUpdates() }
                } else {
                    Text("Mises à jour automatiques non configurées pour ce build (voir docs/UPDATES.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modules: some View {
        Form {
            Section("Médias et système") {
                Toggle("Lecture en cours", isOn: binding(\.modules.media))
                Toggle("Spotify", isOn: binding(\.modules.spotify)).disabled(!state.settings.modules.media)
                Toggle("Musique (Apple Music)", isOn: binding(\.modules.appleMusic)).disabled(!state.settings.modules.media)
                Toggle("Volume", isOn: binding(\.modules.volume))
                Toggle("Changement de sortie audio", isOn: binding(\.modules.audioDevice))
                Toggle("Batterie et alimentation", isOn: binding(\.modules.battery))
                Toggle("Verr. Maj", isOn: binding(\.modules.keyboard))
                Toggle("Périphériques Bluetooth (permission requise)", isOn: binding(\.modules.bluetooth))
                LabeledContent("Verr. Maj") { Text(observedText(state.capsLock)) }
                LabeledContent("Verr. Num") { Text(observedText(state.numLock)) }
            }
            Section("Productivité Apple") {
                Toggle("Calendrier", isOn: binding(\.modules.calendar))
                accessRow("Accès Calendrier", state.calendarAccess, request: actions.requestCalendarAccess, pane: "Privacy_Calendars")
                Toggle("Rappels", isOn: binding(\.modules.reminders))
                accessRow("Accès Rappels", state.remindersAccess, request: actions.requestRemindersAccess, pane: "Privacy_Reminders")
            }
            Section {
                Toggle("iMessage : nombre de messages non lus", isOn: binding(\.modules.iMessage))
                if state.settings.modules.iMessage, state.messagesNeedsPermission {
                    LabeledContent("Accès Accessibilité") {
                        Button("Ouvrir les Réglages Système") { actions.openPrivacySettings("Privacy_Accessibility") }
                    }
                }
            } header: {
                Text("Messages")
            } footer: {
                Text("Apple ne propose pas d’API iMessage : Espazio lit seulement le nombre affiché sur l’icône Messages du Dock (permission Accessibilité), jamais le contenu des messages.")
            }
            Section {
                Toggle("Historique du presse-papiers (5 derniers textes)", isOn: binding(\.modules.clipboard))
            } header: {
                Text("Presse-papiers")
            } footer: {
                Text("Dans les actions rapides (⌃⌥Espace). Conservé en mémoire uniquement, effacé à la fermeture ; les éléments marqués confidentiels par les gestionnaires de mots de passe sont ignorés.")
            }
        }
        .formStyle(.grouped)
    }

    private var agents: some View {
        Form {
            Section("Claude Code") {
                Toggle("Activer", isOn: binding(\.modules.claudeCode))
                Toggle("Hooks Espazio installés (~/.claude/settings.json)", isOn: Binding(
                    get: { state.claudeHooksInstalled }, set: { actions.setClaudeHooksInstalled($0) }))
                Text("Les hooks transmettent à Espazio les événements de session et les demandes d’autorisation. Sans réponse, la demande est refusée ; si Espazio est fermé, Claude Code affiche sa propre demande dans le terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex") {
                Toggle("Activer", isOn: binding(\.modules.codex))
                Button("Suivre les sessions Codex CLI (notify dans ~/.codex/config.toml)") { actions.installCodexNotify() }
                Text("Les sessions lancées depuis Espazio passent par « codex app-server » et sont pilotables. Les sessions CLI indépendantes sont seulement observées.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ChatGPT") {
                Toggle("Afficher l’état de ChatGPT Desktop (meilleur effort)", isOn: binding(\.modules.chatGPT))
            }
            Section("Délai de décision") {
                Slider(value: binding(\.agentRequestTimeout), in: 15...600, step: 15) {
                    Text("Refus automatique après \(Int(state.settings.agentRequestTimeout)) s")
                }
                Button("Afficher le journal d’audit") { actions.revealAuditLog() }
            }
        }
        .formStyle(.grouped)
    }

    @State private var clientID = ""
    @State private var clientSecret = ""

    private var google: some View {
        Form {
            Section("Compte") {
                LabeledContent("État", value: statusText(state.gmailStatus))
                if let account = state.googleAccount { LabeledContent("Compte", value: account) }
                HStack {
                    Button("Connecter") { actions.connectGoogle() }
                    Button("Déconnecter et révoquer") { actions.disconnectGoogle() }
                }
            }
            Section("Client OAuth (application de bureau)") {
                TextField("Client ID", text: $clientID, prompt: Text(state.settings.googleClientID.isEmpty ? "xxxx.apps.googleusercontent.com" : state.settings.googleClientID))
                SecureField("Client secret (stocké dans le trousseau)", text: $clientSecret)
                Button("Enregistrer") {
                    actions.saveGoogleCredentials(clientID: clientID.isEmpty ? state.settings.googleClientID : clientID, clientSecret: clientSecret)
                    clientSecret = ""
                }
                Text("Voir docs/GOOGLE_OAUTH.md. Aucune clé n’est intégrée à Espazio.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Services") {
                Toggle("Gmail", isOn: binding(\.modules.gmail))
                Toggle("Google Chat (comptes Workspace)", isOn: binding(\.modules.googleChat))
                LabeledContent("Google Chat", value: statusText(state.chatStatus))
                Toggle("Google Agenda direct (si non synchronisé dans Calendrier)", isOn: binding(\.modules.googleCalendar))
                Slider(value: binding(\.googleSyncInterval), in: 60...1800, step: 60) {
                    Text("Google Agenda : synchronisation toutes les \(Int(state.settings.googleSyncInterval / 60)) min")
                }
                Toggle("Google Tasks (tâches du jour et en retard, avec les rappels)", isOn: binding(\.modules.googleTasks))
            }
            if let lastError {
                Section { Text(lastError).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var diagnostics: some View {
        Form {
            Toggle("Panneau de diagnostic", isOn: binding(\.diagnosticsEnabled))
            if state.settings.diagnosticsEnabled {
                if let snapshot = state.diagnostics {
                    LabeledContent("Mémoire (empreinte)", value: String(format: "%.1f Mo", snapshot.residentMemoryMB))
                    LabeledContent("Temps CPU cumulé", value: String(format: "%.1f s", snapshot.cpuTimeSeconds))
                    LabeledContent("CPU moyen depuis le lancement", value: String(format: "%.2f %%", snapshot.uptimeSeconds > 0 ? 100 * snapshot.cpuTimeSeconds / snapshot.uptimeSeconds : 0))
                    LabeledContent("Fenêtres notch", value: "\(snapshot.notchWindows)")
                    LabeledContent("Activités en file", value: "\(snapshot.activityItems)")
                    LabeledContent("Pochettes en cache", value: "\(snapshot.artworkCacheItems)")
                    LabeledContent("Bridge local", value: snapshot.bridgeRunning ? "Actif" : "Arrêté")
                    LabeledContent("Processus codex app-server", value: snapshot.codexProcessRunning ? "Lancé" : "Aucun")
                }
                Button("Mesurer maintenant") { actions.refreshDiagnostics() }
            }
            Text("Aucune télémétrie : ces mesures restent sur ce Mac.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { if state.settings.diagnosticsEnabled { actions.refreshDiagnostics() } }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func accessRow(_ title: String, _ access: AccessState, request: @escaping () -> Void, pane: String) -> some View {
        LabeledContent(title) {
            switch access {
            case .granted: Text("Autorisé")
            case .notDetermined: Button("Autoriser", action: request)
            case .denied, .restricted: Button("Ouvrir les Réglages Système") { actions.openPrivacySettings(pane) }
            }
        }
    }

    private func observedText(_ value: Observed<Bool>) -> String {
        switch value {
        case let .value(on): return on ? "Activé" : "Désactivé"
        case let .unavailable(reason): return "Indisponible — \(reason)"
        }
    }

    private func statusText(_ status: ConnectorStatus) -> String {
        switch status {
        case .disconnected: return "Déconnecté"
        case .connecting: return "Connexion…"
        case let .connected(account): return account.map { "Connecté (\($0))" } ?? "Connecté"
        case let .unsupported(reason): return "Non pris en charge : \(reason)"
        case let .error(message, _): return "Erreur : \(message)"
        case .needsReauthorization: return "Reconnexion nécessaire"
        }
    }
}
