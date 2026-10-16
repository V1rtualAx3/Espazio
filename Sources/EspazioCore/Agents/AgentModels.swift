import Foundation

public enum AgentProvider: String, Sendable, Codable, CaseIterable {
    case claudeCode
    case codex
    case chatGPT

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .chatGPT: return "ChatGPT"
        }
    }
}

public enum AgentSessionState: String, Sendable, Codable {
    /// The agent is working.
    case active
    /// The agent waits for the user (permission, question or idle prompt).
    case waiting
    /// The last turn finished successfully.
    case completed
    /// The last turn failed.
    case failed
    /// Session ended (process exited / user quit).
    case ended
}

/// How much Espazio can act on a session. A session that cannot be driven must never be
/// presented as controllable (spec §7).
public enum AgentControlLevel: String, Sendable, Codable {
    /// Status only (e.g. ChatGPT Desktop, Codex CLI history).
    case observeOnly
    /// Espazio can answer permission requests coming through a documented hook.
    case approvals
    /// Espazio owns the session (Codex app-server): approvals, questions, interrupt.
    case full
}

public struct AgentSession: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var provider: AgentProvider
    /// Project directory (cwd) as reported by the agent.
    public var projectPath: String?
    public var title: String?
    public var state: AgentSessionState
    public var lastActivity: Date
    /// When the current turn started (the session became active again); `nil` when idle.
    public var turnStartedAt: Date?
    public var lastMessage: String?
    public var control: AgentControlLevel
    /// Hint used to bring the right terminal / client to front (e.g. `TERM_PROGRAM`).
    public var clientHint: String?

    public init(
        id: String, provider: AgentProvider, projectPath: String? = nil, title: String? = nil,
        state: AgentSessionState, lastActivity: Date, lastMessage: String? = nil,
        control: AgentControlLevel, clientHint: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.projectPath = projectPath
        self.title = title
        self.state = state
        self.lastActivity = lastActivity
        self.lastMessage = lastMessage
        self.control = control
        self.clientHint = clientHint
    }

    /// Last path component of the project, for compact display.
    public var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return title ?? provider.displayName }
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// Normalized lifecycle event coming from any agent integration.
public enum AgentEvent: Sendable, Equatable {
    case sessionStarted(sessionID: String, provider: AgentProvider, projectPath: String?, control: AgentControlLevel, clientHint: String?)
    case activity(sessionID: String, provider: AgentProvider, message: String?)
    case waiting(sessionID: String, provider: AgentProvider, message: String?)
    case turnCompleted(sessionID: String, provider: AgentProvider, message: String?)
    case turnFailed(sessionID: String, provider: AgentProvider, message: String?)
    case sessionEnded(sessionID: String, provider: AgentProvider)

    public var sessionID: String {
        switch self {
        case let .sessionStarted(id, _, _, _, _), let .activity(id, _, _), let .waiting(id, _, _),
            let .turnCompleted(id, _, _), let .turnFailed(id, _, _), let .sessionEnded(id, _):
            return id
        }
    }

    public var provider: AgentProvider {
        switch self {
        case let .sessionStarted(_, provider, _, _, _), let .activity(_, provider, _), let .waiting(_, provider, _),
            let .turnCompleted(_, provider, _), let .turnFailed(_, provider, _), let .sessionEnded(_, provider):
            return provider
        }
    }
}

/// Pure store of known agent sessions, bounded in size.
public struct AgentSessionStore: Sendable, Equatable {
    public private(set) var sessions: [String: AgentSession] = [:]
    public let capacity: Int

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Sessions ordered by state relevance then recency (waiting first).
    public var ordered: [AgentSession] {
        sessions.values.sorted { lhs, rhs in
            let l = Self.rank(lhs.state), r = Self.rank(rhs.state)
            if l != r { return l < r }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    public var hasActivity: Bool { sessions.values.contains { $0.state == .active || $0.state == .waiting } }

    public mutating func apply(_ event: AgentEvent, now: Date) {
        let id = event.sessionID
        let isKnown = sessions[id] != nil
        var session = sessions[id] ?? AgentSession(
            id: id, provider: event.provider, state: .active, lastActivity: now, control: .observeOnly)
        let wasBusy = isKnown && (session.state == .active || session.state == .waiting)
        session.lastActivity = now
        switch event {
        case .sessionStarted, .activity, .waiting:
            if !wasBusy || session.turnStartedAt == nil { session.turnStartedAt = now }
        case .turnCompleted, .turnFailed, .sessionEnded:
            break
        }
        switch event {
        case let .sessionStarted(_, _, projectPath, control, clientHint):
            session.projectPath = projectPath ?? session.projectPath
            // Never downgrade a controllable session because another channel reports it.
            if !isKnown || Self.controlRank(control) > Self.controlRank(session.control) { session.control = control }
            session.clientHint = clientHint ?? session.clientHint
            session.state = .active
        case let .activity(_, _, message):
            session.state = .active
            if let message { session.lastMessage = message }
        case let .waiting(_, _, message):
            session.state = .waiting
            if let message { session.lastMessage = message }
        case let .turnCompleted(_, _, message):
            session.state = .completed
            if let message { session.lastMessage = message }
        case let .turnFailed(_, _, message):
            session.state = .failed
            if let message { session.lastMessage = message }
        case .sessionEnded:
            session.state = .ended
        }
        sessions[id] = session
        enforceCapacity()
    }

    /// Updates metadata learned from another channel (e.g. a permission request carries the cwd).
    public mutating func noteMetadata(sessionID: String, provider: AgentProvider, projectPath: String?, control: AgentControlLevel?, now: Date) {
        var session = sessions[sessionID] ?? AgentSession(
            id: sessionID, provider: provider, state: .active, lastActivity: now, control: control ?? .observeOnly)
        if let projectPath { session.projectPath = projectPath }
        if let control, Self.controlRank(control) > Self.controlRank(session.control) { session.control = control }
        session.lastActivity = now
        sessions[sessionID] = session
        enforceCapacity()
    }

    /// Records how to bring a known session's client to front; every hook event carries it, so a
    /// session first seen after its SessionStart still gets one. Returns whether it changed.
    @discardableResult
    public mutating func noteClientHint(sessionID: String, hint: String?) -> Bool {
        guard let hint, !hint.isEmpty, var session = sessions[sessionID], session.clientHint != hint else { return false }
        session.clientHint = hint
        sessions[sessionID] = session
        return true
    }

    public mutating func remove(sessionID: String) {
        sessions[sessionID] = nil
    }

    /// Drops ended/completed/failed sessions older than `age`.
    public mutating func prune(olderThan age: TimeInterval, now: Date) {
        sessions = sessions.filter { _, session in
            switch session.state {
            case .active, .waiting: return true
            case .completed, .failed, .ended: return now.timeIntervalSince(session.lastActivity) < age
            }
        }
    }

    private mutating func enforceCapacity() {
        guard sessions.count > capacity else { return }
        let victims = ordered.reversed().prefix(sessions.count - capacity)
        for victim in victims { sessions[victim.id] = nil }
    }

    private static func rank(_ state: AgentSessionState) -> Int {
        switch state {
        case .waiting: return 0
        case .active: return 1
        case .failed: return 2
        case .completed: return 3
        case .ended: return 4
        }
    }

    private static func controlRank(_ level: AgentControlLevel) -> Int {
        switch level {
        case .observeOnly: return 0
        case .approvals: return 1
        case .full: return 2
        }
    }
}
