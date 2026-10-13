import EspazioCore
import Foundation

/// Bidirectional line transport (one JSON message per line).
public protocol LineTransport: AnyObject, Sendable {
    /// Incoming lines; finishes when the peer closes.
    var incoming: AsyncStream<Data> { get }
    func send(_ line: Data) throws
    func close()
}

public enum CodexClientError: Error, Equatable, Sendable {
    case notRunning
    case timeout
    case server(code: Int, message: String)
    case invalidResponse
    case executableNotFound
}

/// Client for `codex app-server` (protocol facts in docs/INTEGRATIONS.md):
/// newline-delimited JSON, JSON-RPC-like messages without the `jsonrpc` field.
///
/// Sessions started through this client are fully controllable: approval requests from the
/// server are routed to the shared `ApprovalCenter`, which only answers "accept" after an
/// explicit "Autoriser une fois". Timeouts, disconnections and unknown requests are declined.
public actor CodexAppServerClient {
    public typealias EventSink = @Sendable (AgentEvent) -> Void

    private let transport: LineTransport
    private let approvals: ApprovalCenter
    private let onEvent: EventSink
    private let decisionTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var threads: [String: String?] = [:]
    private var lastAgentMessage: [String: String] = [:]
    /// Paths touched by file-change items, used to describe approval requests.
    private var fileChangePaths = BoundedCache<String, [String]>(countLimit: 64)
    private var initialized = false
    public private(set) var isClosed = false

    public init(
        transport: LineTransport, approvals: ApprovalCenter, decisionTimeout: TimeInterval, requestTimeout: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }, onEvent: @escaping EventSink
    ) {
        self.transport = transport
        self.approvals = approvals
        self.decisionTimeout = decisionTimeout
        self.requestTimeout = requestTimeout
        self.now = now
        self.onEvent = onEvent
    }

    // MARK: - Lifecycle

    /// Starts reading and performs the `initialize` / `initialized` handshake.
    public func start(clientVersion: String) async throws {
        guard readTask == nil else { return }
        let stream = transport.incoming
        readTask = Task { [weak self] in
            for await line in stream {
                await self?.receive(line)
            }
            await self?.transportClosed()
        }
        _ = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("espazio"), "title": .string("Espazio"), "version": .string(clientVersion)]),
        ]))
        try notify("initialized", params: nil)
        initialized = true
    }

    public func stop() {
        transport.close()
    }

    public var activeThreadCount: Int { threads.count }

    // MARK: - Threads & turns

    /// Starts a new thread in `cwd`. Approval policy "on-request" lets the agent ask Espazio.
    public func startThread(cwd: String) async throws -> String {
        let result = try await request("thread/start", params: .object([
            "cwd": .string(cwd), "approvalPolicy": .string("on-request"),
        ]))
        guard let id = result["thread"]?["id"]?.stringValue else { throw CodexClientError.invalidResponse }
        registerThread(id, cwd: cwd)
        return id
    }

    @discardableResult
    public func startTurn(threadID: String, text: String) async throws -> String? {
        let result = try await request("turn/start", params: .object([
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]))
        onEvent(.activity(sessionID: threadID, provider: .codex, message: nil))
        return result["turn"]?["id"]?.stringValue
    }

    public func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request("turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    }

    // MARK: - Outgoing

    func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        guard !isClosed else { throw CodexClientError.notRunning }
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        let line = Data(JSONValue.object(message).compactString().utf8)
        let timeout = requestTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.failPending(id: id, error: CodexClientError.timeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try transport.send(line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: CodexClientError.notRunning)
            }
        }
    }

    private func notify(_ method: String, params: JSONValue?) throws {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        try transport.send(Data(JSONValue.object(message).compactString().utf8))
    }

    private func reply(id: JSONValue, result: JSONValue) {
        try? transport.send(Data(JSONValue.object(["id": id, "result": result]).compactString().utf8))
    }

    private func replyError(id: JSONValue, code: Int, message: String) {
        let error: JSONValue = .object(["code": .number(Double(code)), "message": .string(message)])
        try? transport.send(Data(JSONValue.object(["id": id, "error": error]).compactString().utf8))
    }

    private func failPending(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: - Incoming

    func receive(_ line: Data) async {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line), case .object = message else { return }
        let method = message["method"]?.stringValue
        let id = message["id"]
        switch (method, id) {
        case let (nil, id?):
            handleResponse(id: id, message: message)
        case let (method?, id?):
            let params = message["params"] ?? .null
            Task { await self.handleServerRequest(id: id, method: method, params: params) }
        case let (method?, nil):
            handleNotification(method: method, params: message["params"] ?? .null)
        default:
            break
        }
    }

    private func handleResponse(id: JSONValue, message: JSONValue) {
        guard let number = id.doubleValue, let continuation = pending.removeValue(forKey: Int(number)) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: CodexClientError.server(
                code: Int(error["code"]?.doubleValue ?? -1), message: error["message"]?.stringValue ?? ""))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func handleNotification(method: String, params: JSONValue) {
        let threadID = params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
        switch method {
        case "thread/started":
            if let threadID { registerThread(threadID, cwd: params["thread"]?["cwd"]?.stringValue) }
        case "turn/started":
            if let threadID { onEvent(.activity(sessionID: threadID, provider: .codex, message: nil)) }
        case "item/started":
            if params["item"]?["type"]?.stringValue == "fileChange", let itemID = params["item"]?["id"]?.stringValue {
                let paths = (params["item"]?["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
                fileChangePaths.insert(paths, for: itemID)
            }
        case "item/completed":
            if let threadID, params["item"]?["type"]?.stringValue == "agentMessage", let text = params["item"]?["text"]?.stringValue {
                lastAgentMessage[threadID] = Redactor.truncate(Redactor.redact(text), limit: 200)
            }
        case "turn/completed":
            guard let threadID else { return }
            let status = params["turn"]?["status"]?.stringValue
            let message = lastAgentMessage.removeValue(forKey: threadID)
            if status == "failed" {
                let error = params["turn"]?["error"]?["message"]?.stringValue.map { Redactor.truncate(Redactor.redact($0), limit: 200) }
                onEvent(.turnFailed(sessionID: threadID, provider: .codex, message: error ?? message))
            } else {
                onEvent(.turnCompleted(sessionID: threadID, provider: .codex, message: message))
            }
        case "error":
            if let threadID, params["willRetry"]?.boolValue != true {
                let text = params["error"]?["message"]?.stringValue.map { Redactor.truncate(Redactor.redact($0), limit: 200) }
                onEvent(.turnFailed(sessionID: threadID, provider: .codex, message: text))
            }
        default:
            break
        }
    }

    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) async {
        let threadID = params["threadId"]?.stringValue ?? params["conversationId"]?.stringValue ?? "codex"
        let requestID = "codex:\(threadID):\(id.compactString())"
        let created = now()
        let deadline = created.addingTimeInterval(decisionTimeout)
        let cwd = params["cwd"]?.stringValue ?? threads[threadID] ?? nil
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = Self.commandText(params["command"]) ?? "(commande non communiquée)"
            let request = AgentRequest(
                id: requestID, sessionID: threadID, provider: .codex, kind: .command, toolName: "commandExecution",
                summary: command, workingDirectory: cwd, detail: params["reason"]?.stringValue, createdAt: created, deadline: deadline)
            onEvent(.waiting(sessionID: threadID, provider: .codex, message: "Commande"))
            let response = await approvals.submit(request)
            reply(id: id, result: .object(["decision": .string(Self.decision(response, legacy: method == "execCommandApproval"))]))
            onEvent(.activity(sessionID: threadID, provider: .codex, message: nil))
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let itemID = params["itemId"]?.stringValue
            var paths = itemID.flatMap { fileChangePaths.value(for: $0) } ?? []
            if paths.isEmpty, let changes = params["fileChanges"]?.objectValue { paths = changes.keys.sorted() }
            let summary = paths.isEmpty ? "Modification de fichiers" : paths.joined(separator: "\n")
            let request = AgentRequest(
                id: requestID, sessionID: threadID, provider: .codex, kind: .fileChange, toolName: "fileChange",
                summary: summary, workingDirectory: cwd, detail: params["reason"]?.stringValue, createdAt: created, deadline: deadline)
            onEvent(.waiting(sessionID: threadID, provider: .codex, message: "Fichiers"))
            let response = await approvals.submit(request)
            reply(id: id, result: .object(["decision": .string(Self.decision(response, legacy: method == "applyPatchApproval"))]))
            onEvent(.activity(sessionID: threadID, provider: .codex, message: nil))
        case "item/tool/requestUserInput":
            guard let question = params["questions"]?.arrayValue?.first, let questionID = question["id"]?.stringValue else {
                replyError(id: id, code: -32602, message: "No question")
                return
            }
            let options = (question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
            let text = [question["header"]?.stringValue, question["question"]?.stringValue].compactMap { $0 }.joined(separator: "\n")
            let request = AgentRequest(
                id: requestID, sessionID: threadID, provider: .codex, kind: .question(options: options), toolName: "requestUserInput",
                summary: text, workingDirectory: cwd, detail: nil, createdAt: created, deadline: deadline)
            onEvent(.waiting(sessionID: threadID, provider: .codex, message: "Question"))
            let response = await approvals.submit(request)
            if case let .answer(answer) = response {
                reply(id: id, result: .object(["answers": .object([questionID: .object(["answers": .array([.string(answer)])])])]))
            } else {
                replyError(id: id, code: -32000, message: "Declined by user")
            }
        default:
            // Never leave the server waiting on a request Espazio does not implement.
            replyError(id: id, code: -32601, message: "Method not supported by Espazio")
        }
    }

    private func transportClosed() async {
        isClosed = true
        for continuation in pending.values { continuation.resume(throwing: CodexClientError.notRunning) }
        pending.removeAll()
        await approvals.cancelAll(provider: .codex, reason: .disconnected)
        for threadID in threads.keys { onEvent(.sessionEnded(sessionID: threadID, provider: .codex)) }
        threads.removeAll()
    }

    private func registerThread(_ id: String, cwd: String?) {
        let isNew = threads[id] == nil
        threads[id] = cwd
        if isNew {
            onEvent(.sessionStarted(sessionID: id, provider: .codex, projectPath: cwd, control: .full, clientHint: "espazio"))
        }
    }

    // MARK: - Mapping

    /// "accept" only for an explicit allow-once. User denial declines (the agent continues);
    /// timeouts / disconnections cancel the turn.
    static func decision(_ response: AgentResponse, legacy: Bool) -> String {
        switch response {
        case .allowOnce: return legacy ? "approved" : "accept"
        case .deny(.user), .answer: return legacy ? "denied" : "decline"
        case .deny(.timeout): return legacy ? "timed_out" : "decline"
        case .deny(.cancelled), .deny(.disconnected): return legacy ? "abort" : "cancel"
        }
    }

    static func commandText(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        if let parts = value?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty { return parts.joined(separator: " ") }
        return nil
    }
}
