import AppKit
import EspazioCore
import Observation
import SwiftUI

/// Authorization state of a macOS permission-gated module.
public enum AccessState: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// Tabs of the expanded notch.
public enum NotchTab: String, CaseIterable, Sendable, Identifiable {
    case home
    case agents
    case mail
    case chat

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .home: return "house"
        case .agents: return "sparkles"
        case .mail: return "envelope"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    public var selectedSymbol: String {
        self == .agents ? symbol : symbol + ".fill"
    }

    public var title: String {
        switch self {
        case .home: return "Accueil"
        case .agents: return "Agents IA"
        case .mail: return "Gmail"
        case .chat: return "Google Chat"
        }
    }
}

/// Lightweight diagnostics, refreshed only on demand.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var residentMemoryMB: Double
    public var cpuTimeSeconds: Double
    public var uptimeSeconds: Double
    public var notchWindows: Int
    public var activityItems: Int
    public var artworkCacheItems: Int
    public var bridgeRunning: Bool
    public var codexProcessRunning: Bool

    public init(residentMemoryMB: Double, cpuTimeSeconds: Double, uptimeSeconds: Double, notchWindows: Int, activityItems: Int, artworkCacheItems: Int, bridgeRunning: Bool, codexProcessRunning: Bool) {
        self.residentMemoryMB = residentMemoryMB
        self.cpuTimeSeconds = cpuTimeSeconds
        self.uptimeSeconds = uptimeSeconds
        self.notchWindows = notchWindows
        self.activityItems = activityItems
        self.artworkCacheItems = artworkCacheItems
        self.bridgeRunning = bridgeRunning
        self.codexProcessRunning = codexProcessRunning
    }
}

/// Single observable state shared by every notch window, the palette and settings.
/// Owned and mutated by the app coordinator on the main actor; views only read it.
@MainActor
@Observable
public final class EspazioState {
    public var settings = EspazioSettings()

    // Activities
    public var peek: ActivityItem?
    public var activityCount = 0
    public var pendingDecisionCount = 0

    // Media
    public var nowPlaying: NowPlaying?
    public var artwork: NSImage?
    public var mediaAvailable = false
    /// Name of the player shown ("Spotify", "Musique").
    public var mediaPlayerName = "Spotify"

    // App
    public var launchAtLogin = false
    public var updatesConfigured = false
    public var automaticUpdateChecks = false

    // System
    public var capsLock: Observed<Bool> = .unavailable(reason: "Non observé")
    public let numLock: Observed<Bool> = .unavailable(reason: "Les claviers Mac n’exposent pas d’état Verr. Num observable.")
    public var power: PowerStatus?
    public var outputDeviceName: String?

    // Apple productivity
    public var calendarAccess: AccessState = .notDetermined
    public var remindersAccess: AccessState = .notDetermined
    public var events: [CalendarEvent] = []
    public var reminders = ReminderGroups(overdue: [], today: [])

    // Agents
    public var sessions: [AgentSession] = []
    public var pendingRequests: [AgentRequest] = []
    public var claudeHooksInstalled = false
    public var codexStatus: ConnectorStatus = .disconnected
    public var chatGPTRunning = false

    // Google
    public var gmailStatus: ConnectorStatus = .disconnected
    public var unreadCount: Int?
    public var mail: [MailSummary] = []
    public var gmailCanModify = false
    public var chatStatus: ConnectorStatus = .disconnected
    /// Unread Chat conversations, most recent first.
    public var chatUnread: [ChatUnread] = []
    public var googleAccount: String?

    /// Running countdown (timer or Pomodoro).
    public var timer: NotchTimer?

    // iMessage (Dock badge of Messages)
    public var messagesUnread: Int?
    /// The Accessibility permission is missing for the iMessage badge.
    public var messagesNeedsPermission = false

    // Diagnostics
    public var diagnostics: DiagnosticsSnapshot?

    public init() {}

    /// Next event that has not ended.
    public func nextEvent(now: Date) -> CalendarEvent? {
        events.first { !$0.isAllDay && $0.end > now } ?? events.first { $0.end > now }
    }

    /// Tabs to show, according to enabled modules.
    public var visibleTabs: [NotchTab] {
        var tabs: [NotchTab] = [.home]
        let modules = settings.modules
        if modules.claudeCode || modules.codex || modules.chatGPT { tabs.append(.agents) }
        if modules.gmail { tabs.append(.mail) }
        if modules.googleChat { tabs.append(.chat) }
        return tabs
    }
}

/// Every user intent coming from the UI. Implemented by the app coordinator; previews and tests
/// use `NoopActions`.
@MainActor
public protocol EspazioActions: AnyObject {
    // Media
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func openMediaApp()
    // Calendar & reminders
    func requestCalendarAccess()
    func requestRemindersAccess()
    func openEvent(_ event: CalendarEvent)
    func joinMeeting(_ url: URL)
    func completeReminder(id: String)
    func createReminder(title: String, due: Date?, hasDueTime: Bool)
    func openReminders()
    // Agents
    func resolve(_ request: AgentRequest, response: AgentResponse)
    func openSession(_ session: AgentSession)
    func openChatGPT()
    func startCodexSession()
    // Gmail
    func connectGoogle()
    func openMail(_ mail: MailSummary)
    func markMailRead(_ mail: MailSummary)
    func archiveMail(_ mail: MailSummary)
    func refreshGoogle()
    // Chat
    func openChat(_ chat: ChatUnread)
    func openMessages()
    // App
    func setFocusMode(_ mode: FocusMode)
    func openSettings()
    func collapseNotch()
    func dismissPeek()
}

/// Inert implementation for previews and UI tests.
@MainActor
public final class NoopActions: EspazioActions {
    public init() {}
    public func togglePlayPause() {}
    public func nextTrack() {}
    public func previousTrack() {}
    public func openMediaApp() {}
    public func requestCalendarAccess() {}
    public func requestRemindersAccess() {}
    public func openEvent(_ event: CalendarEvent) {}
    public func joinMeeting(_ url: URL) {}
    public func completeReminder(id: String) {}
    public func createReminder(title: String, due: Date?, hasDueTime: Bool) {}
    public func openReminders() {}
    public func resolve(_ request: AgentRequest, response: AgentResponse) {}
    public func openSession(_ session: AgentSession) {}
    public func openChatGPT() {}
    public func startCodexSession() {}
    public func connectGoogle() {}
    public func openMail(_ mail: MailSummary) {}
    public func markMailRead(_ mail: MailSummary) {}
    public func archiveMail(_ mail: MailSummary) {}
    public func refreshGoogle() {}
    public func openChat(_ chat: ChatUnread) {}
    public func openMessages() {}
    public func setFocusMode(_ mode: FocusMode) {}
    public func openSettings() {}
    public func collapseNotch() {}
    public func dismissPeek() {}
}

/// Per-window presentation state (each screen has its own hover / expansion).
@MainActor
@Observable
public final class NotchPresentation {
    public var state: NotchState = .collapsed
    public var tab: NotchTab = .home
    public var geometry: NotchGeometry
    /// Hidden because a full-screen app occupies this display (user option).
    public var suppressed = false

    public init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}
