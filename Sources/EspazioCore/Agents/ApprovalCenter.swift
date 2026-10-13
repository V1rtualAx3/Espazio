import Foundation

/// What an agent is asking for.
public enum AgentRequestKind: Sendable, Equatable, Codable {
    /// Run a shell command.
    case command
    /// Modify files.
    case fileChange
    /// Use another tool (MCP, web fetch…).
    case tool
    /// Short question that expects a text answer; `options` may be empty.
    case question(options: [String])

    public var isQuestion: Bool {
        if case .question = self { return true }
        return false
    }
}

/// A pending agent decision. Everything shown to the user before deciding is in here
/// (spec §7: session identity, full command, directory and context).
public struct AgentRequest: Sendable, Equatable, Identifiable, Codable {
    /// Unique request identifier (unique across sessions).
    public let id: String
    public let sessionID: String
    public let provider: AgentProvider
    public let kind: AgentRequestKind
    /// Tool name as reported by the agent (`Bash`, `Edit`, `commandExecution`…).
    public let toolName: String
    /// Full command / description. Never truncated in the model; the UI may scroll.
    public let summary: String
    public let workingDirectory: String?
    /// Optional reason or extra context given by the agent.
    public let detail: String?
    public let createdAt: Date
    /// After this instant the request is resolved as denied (never allowed).
    public let deadline: Date

    public init(
        id: String, sessionID: String, provider: AgentProvider, kind: AgentRequestKind, toolName: String,
        summary: String, workingDirectory: String?, detail: String?, createdAt: Date, deadline: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.provider = provider
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.detail = detail
        self.createdAt = createdAt
        self.deadline = deadline
    }
}

public enum DenialReason: String, Sendable, Codable, Equatable {
    /// The user clicked "Refuser".
    case user
    /// Nobody answered before the deadline.
    case timeout
    /// The request was withdrawn (agent cancelled, Espazio quit…).
    case cancelled
    /// The channel to the agent was lost.
    case disconnected
}

/// The only possible outcomes. There is deliberately no "always allow" scope (spec §3.6).
public enum AgentResponse: Sendable, Equatable, Codable {
    case allowOnce
    case deny(DenialReason)
    case answer(String)

    public var isAllowed: Bool { self == .allowOnce }
}

public enum ResolveResult: Sendable, Equatable {
    case applied
    /// The request was already resolved; the original response is kept (idempotent).
    case alreadyResolved(AgentResponse)
    case unknownRequest
    /// The caller referenced a different session than the one owning the request.
    case sessionMismatch
    /// Response type does not match the request kind (e.g. an answer for a command approval).
    case invalidResponse
}

/// Audit entry without secrets: no command text, no answer text.
public struct ApprovalAuditEvent: Sendable, Equatable {
    public enum Action: String, Sendable { case submitted, resolved, rejectedResolution }
    public let action: Action
    public let requestID: String
    public let sessionID: String
    public let provider: AgentProvider
    public let toolName: String
    public let outcome: String?
    public let date: Date

    public init(action: Action, requestID: String, sessionID: String, provider: AgentProvider, toolName: String, outcome: String?, date: Date) {
        self.action = action
        self.requestID = requestID
        self.sessionID = sessionID
        self.provider = provider
        self.toolName = toolName
        self.outcome = outcome
        self.date = date
    }
}

/// Single source of truth for agent decisions, shared by every notch on every screen.
///
/// Guarantees:
/// - deny by default: timeouts, cancellations and disconnections resolve as `.deny`;
/// - a request is resolved at most once; later resolutions return `.alreadyResolved`;
/// - resolving requires the matching session identifier;
/// - re-submitting a known request id (helper retry) waits for / returns the same response.
public actor ApprovalCenter {
    public static let minimumTimeout: TimeInterval = 5
    public static let maximumTimeout: TimeInterval = 600

    private struct Pending {
        var request: AgentRequest
        var waiters: [CheckedContinuation<AgentResponse, Never>]
        var timeoutTask: Task<Void, Never>?
    }

    private struct Resolved {
        let sessionID: String
        let response: AgentResponse
    }

    private var pending: [String: Pending] = [:]
    /// FIFO order of pending ids.
    private var order: [String] = []
    private var resolved: [String: Resolved] = [:]
    private var resolvedOrder: [String] = []
    private let resolvedCapacity: Int
    private let maxPending: Int
    private let now: @Sendable () -> Date
    private let audit: (@Sendable (ApprovalAuditEvent) -> Void)?
    private var observers: [UUID: AsyncStream<[AgentRequest]>.Continuation] = [:]

    public init(
        maxPending: Int = 64,
        resolvedCapacity: Int = 512,
        now: @escaping @Sendable () -> Date = { Date() },
        audit: (@Sendable (ApprovalAuditEvent) -> Void)? = nil
    ) {
        self.maxPending = maxPending
        self.resolvedCapacity = resolvedCapacity
        self.now = now
        self.audit = audit
    }

    /// Pending requests, oldest first.
    public var pendingRequests: [AgentRequest] { order.compactMap { pending[$0]?.request } }

    /// Submits a request and suspends until it is resolved. Never returns `.allowOnce` unless a
    /// user explicitly resolved it with `.allowOnce`.
    public func submit(_ request: AgentRequest) async -> AgentResponse {
        if let done = resolved[request.id] {
            return done.sessionID == request.sessionID ? done.response : .deny(.cancelled)
        }
        if let existing = pending[request.id], existing.request.sessionID != request.sessionID {
            // Same id claimed by another session: refuse the newcomer, keep the original.
            return .deny(.cancelled)
        }
        if pending[request.id] == nil {
            guard pending.count < maxPending else { return .deny(.cancelled) }
            let current = now()
            let timeout = min(max(request.deadline.timeIntervalSince(current), Self.minimumTimeout), Self.maximumTimeout)
            let clamped = AgentRequest(
                id: request.id, sessionID: request.sessionID, provider: request.provider, kind: request.kind,
                toolName: request.toolName, summary: request.summary, workingDirectory: request.workingDirectory,
                detail: request.detail, createdAt: request.createdAt, deadline: current.addingTimeInterval(timeout))
            let id = request.id
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.finish(id: id, response: .deny(.timeout))
            }
            pending[id] = Pending(request: clamped, waiters: [], timeoutTask: task)
            order.append(id)
            record(.submitted, clamped, outcome: nil)
            broadcast()
        }
        return await withCheckedContinuation { continuation in
            pending[request.id]?.waiters.append(continuation)
        }
    }

    /// Resolves a request on behalf of the user.
    @discardableResult
    public func resolve(requestID: String, sessionID: String, response: AgentResponse) -> ResolveResult {
        if let done = resolved[requestID] {
            return done.sessionID == sessionID ? .alreadyResolved(done.response) : .sessionMismatch
        }
        guard let entry = pending[requestID] else { return .unknownRequest }
        guard entry.request.sessionID == sessionID else {
            record(.rejectedResolution, entry.request, outcome: "sessionMismatch")
            return .sessionMismatch
        }
        switch (entry.request.kind.isQuestion, response) {
        case (false, .answer), (true, .allowOnce):
            record(.rejectedResolution, entry.request, outcome: "invalidResponse")
            return .invalidResponse
        default:
            break
        }
        finish(id: requestID, response: response)
        return .applied
    }

    /// Withdraws one request (the agent no longer waits for it).
    public func cancel(requestID: String, reason: DenialReason = .cancelled) {
        finish(id: requestID, response: .deny(reason))
    }

    /// Withdraws every request of a session (bridge connection closed, process exited…).
    public func cancelAll(sessionID: String, reason: DenialReason = .disconnected) {
        for id in order where pending[id]?.request.sessionID == sessionID {
            finish(id: id, response: .deny(reason))
        }
    }

    public func cancelAll(provider: AgentProvider, reason: DenialReason = .disconnected) {
        for id in order where pending[id]?.request.provider == provider {
            finish(id: id, response: .deny(reason))
        }
    }

    /// Stream of pending-request snapshots; yields the current state immediately.
    public func updates() -> AsyncStream<[AgentRequest]> {
        let (stream, continuation) = AsyncStream<[AgentRequest]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        observers[token] = continuation
        continuation.yield(pendingRequests)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    // MARK: - Private

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func finish(id: String, response: AgentResponse) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        entry.timeoutTask?.cancel()
        resolved[id] = Resolved(sessionID: entry.request.sessionID, response: response)
        resolvedOrder.append(id)
        if resolvedOrder.count > resolvedCapacity {
            let overflow = resolvedOrder.count - resolvedCapacity
            for old in resolvedOrder.prefix(overflow) { resolved[old] = nil }
            resolvedOrder.removeFirst(overflow)
        }
        record(.resolved, entry.request, outcome: Self.describe(response))
        for waiter in entry.waiters { waiter.resume(returning: response) }
        broadcast()
    }

    private func broadcast() {
        let snapshot = pendingRequests
        for observer in observers.values { observer.yield(snapshot) }
    }

    private func record(_ action: ApprovalAuditEvent.Action, _ request: AgentRequest, outcome: String?) {
        audit?(ApprovalAuditEvent(
            action: action, requestID: request.id, sessionID: request.sessionID, provider: request.provider,
            toolName: request.toolName, outcome: outcome, date: now()))
    }

    private static func describe(_ response: AgentResponse) -> String {
        switch response {
        case .allowOnce: return "allowOnce"
        case let .deny(reason): return "deny:\(reason.rawValue)"
        case .answer: return "answered"
        }
    }
}
