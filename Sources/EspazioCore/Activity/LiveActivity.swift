import Foundation

/// What the notch may keep showing at rest ("affichage continu"), chosen by the user.
public struct LiveActivitySettings: Sendable, Codable, Equatable {
    /// Track currently playing.
    public var media = true
    /// Keep the track shown while paused (otherwise it fades a few seconds after pause).
    public var mediaWhenPaused = false
    /// Countdown to the next meeting once it is within `eventLeadMinutes`.
    public var nextEvent = true
    public var eventLeadMinutes = 30
    /// Active / waiting AI agent sessions.
    public var agents = true
    /// Discreet unread Gmail count (envelope + number). Stored under a new key so it is on for
    /// everyone, including users who had the former opt-in "unreadMail" item off.
    public var mailBadge = true
    /// Discreet count of Google Chat conversations with new messages.
    public var chatBadge = true
    /// Discreet unread iMessage count (Messages' Dock badge).
    public var messagesBadge = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LiveActivitySettings()
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? d.media
        mediaWhenPaused = try c.decodeIfPresent(Bool.self, forKey: .mediaWhenPaused) ?? d.mediaWhenPaused
        nextEvent = try c.decodeIfPresent(Bool.self, forKey: .nextEvent) ?? d.nextEvent
        eventLeadMinutes = min(max(try c.decodeIfPresent(Int.self, forKey: .eventLeadMinutes) ?? d.eventLeadMinutes, 5), 240)
        agents = try c.decodeIfPresent(Bool.self, forKey: .agents) ?? d.agents
        mailBadge = try c.decodeIfPresent(Bool.self, forKey: .mailBadge) ?? d.mailBadge
        chatBadge = try c.decodeIfPresent(Bool.self, forKey: .chatBadge) ?? d.chatBadge
        messagesBadge = try c.decodeIfPresent(Bool.self, forKey: .messagesBadge) ?? d.messagesBadge
    }
}

/// Coalescing keys of the continuous items (one is shown at a time).
public enum LiveActivityKey {
    public static let media = "media"
    public static let event = "live-event"
    public static let agents = "live-agents"
    public static let mail = "live-mail"
    public static let chat = "live-chat"
    public static let messages = "live-imessage"
    public static let all = [media, event, agents, mail, chat, messages]
}

/// Inputs available to the planner, already filtered by module switches.
public struct LiveActivityInputs: Sendable, Equatable {
    public var nowPlaying: NowPlaying?
    public var nextEvent: CalendarEvent?
    public var waitingAgents: Int
    public var activeAgents: Int
    public var unreadMail: Int?
    public var unreadChats: Int
    public var unreadMessages: Int

    public init(
        nowPlaying: NowPlaying? = nil, nextEvent: CalendarEvent? = nil, waitingAgents: Int = 0, activeAgents: Int = 0,
        unreadMail: Int? = nil, unreadChats: Int = 0, unreadMessages: Int = 0
    ) {
        self.nowPlaying = nowPlaying
        self.nextEvent = nextEvent
        self.waitingAgents = waitingAgents
        self.activeAgents = activeAgents
        self.unreadMail = unreadMail
        self.unreadChats = unreadChats
        self.unreadMessages = unreadMessages
    }
}

/// Chooses the single continuous item to keep in the notch (spec §2: one prioritized piece of
/// information). Priority: waiting agent > imminent meeting > media > active agents > unread mail >
/// unread chats > unread iMessages. Unread counts also stay visible as small badges next to any other item
/// (`NotchBadges`), so a playing track never hides them.
/// Items are P4 without expiry: any transient notification takes precedence, then the continuous
/// item comes back.
public enum LiveActivityPlanner {
    public static func select(_ inputs: LiveActivityInputs, settings: LiveActivitySettings, now: Date) -> ActivityItem? {
        if settings.agents, inputs.waitingAgents > 0 {
            return item(LiveActivityKey.agents, source: .agents, title: "En attente",
                        subtitle: inputs.waitingAgents > 1 ? "\(inputs.waitingAgents) agents" : "Agent IA", symbol: "hand.raised", now: now)
        }
        if settings.nextEvent, let event = inputs.nextEvent, !event.isAllDay {
            let lead = TimeInterval(settings.eventLeadMinutes * 60)
            let untilStart = event.start.timeIntervalSince(now)
            if untilStart <= lead, now < event.end {
                return item(LiveActivityKey.event, source: .calendar, title: event.title,
                            subtitle: CountdownFormatter.string(until: event.start, end: event.end, now: now),
                            symbol: "calendar", reference: event.id, now: now)
            }
        }
        if settings.media, let playing = inputs.nowPlaying, playing.state == .playing || settings.mediaWhenPaused {
            return item(LiveActivityKey.media, source: .media, title: playing.title, subtitle: playing.artist,
                        symbol: playing.state == .playing ? "music.note" : "pause.fill", now: now)
        }
        if settings.agents, inputs.activeAgents > 0 {
            return item(LiveActivityKey.agents, source: .agents, title: "Agents IA",
                        subtitle: inputs.activeAgents > 1 ? "\(inputs.activeAgents) actifs" : "1 actif", symbol: "sparkles", now: now)
        }
        if settings.mailBadge, let unread = inputs.unreadMail, unread > 0 {
            return item(LiveActivityKey.mail, source: .mail, title: "E-mails non lus", subtitle: BadgeCount.text(unread),
                        symbol: "envelope", now: now)
        }
        if settings.chatBadge, inputs.unreadChats > 0 {
            return item(LiveActivityKey.chat, source: .chat, title: "Google Chat", subtitle: BadgeCount.text(inputs.unreadChats),
                        symbol: "bubble.left", now: now)
        }
        if settings.messagesBadge, inputs.unreadMessages > 0 {
            return item(LiveActivityKey.messages, source: .chat, title: "iMessage", subtitle: BadgeCount.text(inputs.unreadMessages),
                        symbol: "message", now: now)
        }
        return nil
    }

    /// Next instant at which the selection may change on its own (a meeting entering the lead
    /// window or ending), so the owner can schedule one timer instead of polling.
    public static func nextChange(_ inputs: LiveActivityInputs, settings: LiveActivitySettings, now: Date) -> Date? {
        guard settings.nextEvent, let event = inputs.nextEvent, !event.isAllDay else { return nil }
        let entry = event.start.addingTimeInterval(-TimeInterval(settings.eventLeadMinutes * 60))
        return [entry, event.end].filter { $0 > now }.min()
    }

    private static func item(
        _ key: String, source: ActivitySource, title: String, subtitle: String?, symbol: String, reference: String? = nil, now: Date
    ) -> ActivityItem {
        // Fixed createdAt so re-posting identical content is a no-op (no re-animation).
        ActivityItem(source: source, priority: .p4, coalescingKey: key, title: title, subtitle: subtitle, symbol: symbol,
                     reference: reference, createdAt: Date(timeIntervalSince1970: 0))
    }
}

/// Compact counter text for badges ("1"…"99", then "99+").
public enum BadgeCount {
    public static func text(_ count: Int) -> String { count > 99 ? "99+" : String(max(count, 0)) }
}
