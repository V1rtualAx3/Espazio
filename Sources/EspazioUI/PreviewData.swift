import AppKit
import EspazioCore
import SwiftUI

/// Offline sample data for SwiftUI previews and UI tests (no network, no permission).
@MainActor
public enum PreviewData {
    public static let builtInScreen = ScreenDescriptor(
        id: 1, localizedName: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
        auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664, isMain: true)

    public static let externalScreen = ScreenDescriptor(
        id: 2, localizedName: "Studio Display", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isMain: false)

    public static func state(longStrings: Bool = false, pendingRequest: Bool = true) -> EspazioState {
        let now = Date()
        let state = EspazioState()
        state.settings.modules.gmail = true
        state.settings.modules.googleChat = true
        let long = longStrings ? String(repeating: " — un titre particulièrement long pour tester la troncature", count: 3) : ""
        state.nowPlaying = NowPlaying(
            trackID: "spotify:track:1", title: "Clair de lune" + long, artist: "Claude Debussy", state: .playing,
            duration: 300, position: 42, positionDate: now)
        state.mediaAvailable = true
        state.calendarAccess = .granted
        state.remindersAccess = .granted
        state.events = [
            CalendarEvent(id: "e1", title: "Point produit Espazio" + long, start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
                          location: "https://meet.google.com/abc-defg-hij", source: .eventKit),
        ]
        state.reminders = ReminderGroups(
            overdue: [ReminderItem(id: "r1", title: "Envoyer la facture" + long, due: now.addingTimeInterval(-7200))],
            today: [ReminderItem(id: "r2", title: "Relire la PR M1", due: now.addingTimeInterval(3600))])
        state.sessions = [
            AgentSession(id: "s1", provider: .claudeCode, projectPath: "/Users/me/Espazio", state: .waiting, lastActivity: now,
                         lastMessage: "Bash", control: .approvals, clientHint: "com.apple.Terminal"),
            AgentSession(id: "s2", provider: .codex, projectPath: "/Users/me/api", state: .completed, lastActivity: now.addingTimeInterval(-300),
                         lastMessage: "Tests verts" + long, control: .observeOnly),
        ]
        if pendingRequest {
            state.pendingRequests = [
                AgentRequest(id: "claude:s1:t1", sessionID: "s1", provider: .claudeCode, kind: .command, toolName: "Bash",
                             summary: "swift test --parallel && git push origin feature/notch" + long, workingDirectory: "/Users/me/Espazio",
                             detail: "Lancer les tests puis pousser la branche", createdAt: now, deadline: now.addingTimeInterval(300)),
            ]
        }
        state.pendingDecisionCount = state.pendingRequests.count
        state.claudeHooksInstalled = true
        state.gmailStatus = .connected(account: "moi@example.com")
        state.unreadCount = 3
        state.mail = [
            MailSummary(id: "m1", threadID: "t1", from: "\"Alice Martin\" <alice@example.com>", subject: "Maquettes V1" + long,
                        snippet: "Voici les dernières maquettes de la notch…", date: now.addingTimeInterval(-900), isUnread: true),
        ]
        state.chatStatus = .unsupported(reason: "Google Chat nécessite un compte Google Workspace.")
        state.capsLock = .value(false)
        return state
    }

    public static func presentation(_ notchState: NotchState, tab: NotchTab = .home, screen: ScreenDescriptor = builtInScreen) -> NotchPresentation {
        let presentation = NotchPresentation(geometry: NotchGeometry(screen: screen))
        presentation.state = notchState
        presentation.tab = tab
        return presentation
    }

    public static let volumePeek = ActivityItem(
        source: .volume, priority: .p3, coalescingKey: "volume", title: "Volume", symbol: "speaker.wave.2.fill",
        progress: 0.55, createdAt: Date())

    public static let approvalPeek = ActivityItem(
        source: .agents, priority: .p0, coalescingKey: "approval:x", title: "Autorisation", subtitle: "Claude Code",
        symbol: "exclamationmark.shield", createdAt: Date(), requiresDecision: true)
}

struct NotchPreviews: PreviewProvider {
    @MainActor
    static func notch(_ notchState: NotchState, tab: NotchTab = .home, peek: ActivityItem? = nil, long: Bool = false) -> some View {
        let state = PreviewData.state(longStrings: long)
        state.peek = peek
        let presentation = PreviewData.presentation(notchState, tab: tab)
        let size = presentation.geometry.contentSize(for: .expanded)
        return NotchRootView(presentation: presentation, state: state, actions: NoopActions())
            .frame(width: size.width + 40, height: size.height + 20)
            .background(Color.gray.opacity(0.3))
    }

    static var previews: some View {
        Group {
            notch(.collapsed).previewDisplayName("Collapsed")
            notch(.peek, peek: PreviewData.volumePeek).previewDisplayName("Peek — volume")
            notch(.peek, peek: PreviewData.approvalPeek).previewDisplayName("Peek — autorisation IA")
            notch(.expanded).previewDisplayName("Expanded — accueil")
            notch(.expanded, tab: .agents).previewDisplayName("Expanded — agents")
            notch(.expanded, tab: .mail, long: true).previewDisplayName("Expanded — mail, chaînes longues")
            notch(.expanded, tab: .agents, long: true).environment(\.colorScheme, .light).previewDisplayName("Agents — mode clair")
        }
    }
}
