@testable import AgentIntegrations
import EspazioCore
import XCTest

/// In-memory transport: the test plays the app-server.
final class FakeTransport: LineTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sent: [JSONValue] = []
    private var closed = false

    init() {
        (incoming, continuation) = AsyncStream<Data>.makeStream()
    }

    func send(_ line: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CodexClientError.notRunning }
        sent.append(try JSONDecoder().decode(JSONValue.self, from: line))
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        continuation.finish()
    }

    /// Server → client.
    func emit(_ json: String) {
        continuation.yield(Data(json.utf8))
    }

    func messages() -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    /// Waits for a client message matching `predicate`.
    func waitFor(_ predicate: (JSONValue) -> Bool, timeout: TimeInterval = 3) async -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = messages().first(where: predicate) { return match }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    func record(_ event: AgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func all() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Polls the center until `count` requests are pending (plain `while` loop: a `for … where`
/// over a variable mutated across `await` is miscompiled by Swift 6.1 on Linux).
func pendingRequests(_ center: ApprovalCenter, atLeast count: Int, timeout: TimeInterval = 2) async -> [AgentRequest] {
    let deadline = Date().addingTimeInterval(timeout)
    var current = await center.pendingRequests
    while current.count < count, Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
        current = await center.pendingRequests
    }
    return current
}

final class CodexTests: XCTestCase {
    func makeClient(timeout: TimeInterval = 60) -> (CodexAppServerClient, FakeTransport, ApprovalCenter, EventRecorder) {
        let transport = FakeTransport()
        let center = ApprovalCenter()
        let recorder = EventRecorder()
        let client = CodexAppServerClient(transport: transport, approvals: center, decisionTimeout: timeout, requestTimeout: 2) { recorder.record($0) }
        return (client, transport, center, recorder)
    }

    /// Answers the initialize request and returns once the handshake is done.
    func handshake(_ client: CodexAppServerClient, _ transport: FakeTransport) async throws {
        async let started: Void = client.start(clientVersion: "0.1.0")
        let initialize = await transport.waitFor { $0["method"]?.stringValue == "initialize" }
        XCTAssertNil(initialize?["jsonrpc"], "app-server protocol omits the jsonrpc field")
        XCTAssertEqual(initialize?["params"]?["clientInfo"]?["name"]?.stringValue, "espazio")
        transport.emit(#"{"id":1,"result":{"userAgent":"codex"}}"#)
        try await started
        let initialized = await transport.waitFor { $0["method"]?.stringValue == "initialized" }
        XCTAssertNotNil(initialized)
        XCTAssertNil(initialized?["id"])
    }

    func testHandshakeThreadAndTurn() async throws {
        let (client, transport, _, recorder) = makeClient()
        try await handshake(client, transport)

        async let thread = client.startThread(cwd: "/tmp/proj")
        let start = await transport.waitFor { $0["method"]?.stringValue == "thread/start" }
        XCTAssertEqual(start?["params"]?["approvalPolicy"]?.stringValue, "on-request")
        transport.emit(#"{"id":2,"result":{"thread":{"id":"th_1"}}}"#)
        let threadID = try await thread
        XCTAssertEqual(threadID, "th_1")

        async let turn = client.startTurn(threadID: "th_1", text: "Lance les tests")
        let turnStart = await transport.waitFor { $0["method"]?.stringValue == "turn/start" }
        XCTAssertEqual(turnStart?["params"]?["input"]?.arrayValue?.first?["type"]?.stringValue, "text")
        transport.emit(#"{"id":3,"result":{"turn":{"id":"tu_1","status":"inProgress"}}}"#)
        _ = try await turn

        transport.emit(#"{"method":"item/completed","params":{"threadId":"th_1","turnId":"tu_1","item":{"type":"agentMessage","id":"i1","text":"Tous les tests passent"}}}"#)
        transport.emit(#"{"method":"turn/completed","params":{"threadId":"th_1","turn":{"id":"tu_1","status":"completed"}}}"#)
        try await Task.sleep(nanoseconds: 100_000_000)
        let events = recorder.all()
        XCTAssertTrue(events.contains(.sessionStarted(sessionID: "th_1", provider: .codex, projectPath: "/tmp/proj", control: .full, clientHint: "espazio")))
        XCTAssertTrue(events.contains(.turnCompleted(sessionID: "th_1", provider: .codex, message: "Tous les tests passent")))
    }

    func testCommandApprovalAcceptOnlyAfterExplicitAllow() async throws {
        let (client, transport, center, _) = makeClient()
        try await handshake(client, transport)
        transport.emit(#"{"id":"srv-1","method":"item/commandExecution/requestApproval","params":{"threadId":"th_9","turnId":"t","itemId":"i","startedAtMs":0,"command":"rm -rf dist","cwd":"/p","reason":"cleanup"}}"#)
        let pending = await pendingRequests(center, atLeast: 1)
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.summary, "rm -rf dist")
        XCTAssertEqual(request.workingDirectory, "/p")
        XCTAssertEqual(request.sessionID, "th_9")
        XCTAssertNil(transport.messages().first { $0["id"]?.stringValue == "srv-1" }, "no answer before the user decides")

        await center.resolve(requestID: request.id, sessionID: "th_9", response: .allowOnce)
        let reply = await transport.waitFor { $0["id"]?.stringValue == "srv-1" }
        XCTAssertEqual(reply?["result"]?["decision"]?.stringValue, "accept")
    }

    func testDenialAndDisconnectMapping() async throws {
        let (client, transport, center, recorder) = makeClient()
        try await handshake(client, transport)
        transport.emit(#"{"id":7,"method":"item/fileChange/requestApproval","params":{"threadId":"th","turnId":"t","itemId":"i","startedAtMs":0}}"#)
        transport.emit(#"{"id":8,"method":"item/commandExecution/requestApproval","params":{"threadId":"th","turnId":"t","itemId":"j","startedAtMs":0,"command":"ls"}}"#)
        let pending = await pendingRequests(center, atLeast: 2)
        let fileRequest = try XCTUnwrap(pending.first { $0.kind == .fileChange })
        await center.resolve(requestID: fileRequest.id, sessionID: "th", response: .deny(.user))
        let reply = await transport.waitFor { $0["id"]?.doubleValue == 7 }
        XCTAssertEqual(reply?["result"]?["decision"]?.stringValue, "decline")

        // Server goes away while a request is pending: it is cancelled, never approved.
        transport.close()
        for _ in 0..<100 {
            if await center.pendingRequests.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let remaining = await center.pendingRequests
        XCTAssertTrue(remaining.isEmpty)
        let closed = await client.isClosed
        XCTAssertTrue(closed)
        _ = recorder
    }

    func testUnknownServerRequestGetsError() async throws {
        let (client, transport, _, _) = makeClient()
        try await handshake(client, transport)
        transport.emit(#"{"id":42,"method":"account/chatgptAuthTokens/refresh","params":{}}"#)
        let reply = await transport.waitFor { $0["id"]?.doubleValue == 42 }
        XCTAssertEqual(reply?["error"]?["code"]?.doubleValue, -32601)
    }

    func testQuestionAnswer() async throws {
        let (client, transport, center, _) = makeClient()
        try await handshake(client, transport)
        transport.emit(#"{"id":11,"method":"item/tool/requestUserInput","params":{"threadId":"th","turnId":"t","itemId":"i","isBlocking":true,"questions":[{"id":"q1","header":"Base","question":"Quelle branche ?","options":[{"label":"main","description":""},{"label":"dev","description":""}]}]}}"#)
        let pending = await pendingRequests(center, atLeast: 1)
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.kind, .question(options: ["main", "dev"]))
        await center.resolve(requestID: request.id, sessionID: "th", response: .answer("dev"))
        let reply = await transport.waitFor { $0["id"]?.doubleValue == 11 }
        XCTAssertEqual(reply?["result"]?["answers"]?["q1"]?["answers"]?.arrayValue?.first?.stringValue, "dev")
    }

    func testRequestTimeout() async throws {
        let (client, transport, _, _) = makeClient()
        try await handshake(client, transport)
        do {
            _ = try await client.startThread(cwd: "/tmp")
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .timeout)
        }
    }

    func testServerErrorResponse() async throws {
        let (client, transport, _, _) = makeClient()
        try await handshake(client, transport)
        async let thread = client.startThread(cwd: "/tmp")
        _ = await transport.waitFor { $0["method"]?.stringValue == "thread/start" }
        transport.emit(#"{"id":2,"error":{"code":-32600,"message":"bad"}}"#)
        do {
            _ = try await thread
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .server(code: -32600, message: "bad"))
        }
    }

    func testFileChangeApprovalCarriesDiff() async throws {
        let (client, transport, center, _) = makeClient()
        try await handshake(client, transport)
        transport.emit(#"{"method":"item/started","params":{"threadId":"th","turnId":"t","item":{"type":"fileChange","id":"fc1","changes":[{"path":"src/a.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}]}}}"#)
        transport.emit(#"{"id":5,"method":"item/fileChange/requestApproval","params":{"threadId":"th","turnId":"t","itemId":"fc1","startedAtMs":0}}"#)
        let pending = await pendingRequests(center, atLeast: 1)
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.summary, "src/a.swift")
        XCTAssertEqual(request.diffs.first?.lines, [.init(.hunk, "@@ -1 +1 @@"), .init(.removed, "old"), .init(.added, "new")])
        await center.resolve(requestID: request.id, sessionID: "th", response: .deny(.user))
    }

    func testDecisionMapping() {
        XCTAssertEqual(CodexAppServerClient.decision(.allowOnce, legacy: false), "accept")
        XCTAssertEqual(CodexAppServerClient.decision(.deny(.user), legacy: false), "decline")
        XCTAssertEqual(CodexAppServerClient.decision(.deny(.timeout), legacy: false), "decline")
        XCTAssertEqual(CodexAppServerClient.decision(.deny(.disconnected), legacy: false), "cancel")
        XCTAssertEqual(CodexAppServerClient.decision(.allowOnce, legacy: true), "approved")
        XCTAssertEqual(CodexAppServerClient.decision(.deny(.user), legacy: true), "denied")
        XCTAssertEqual(CodexAppServerClient.commandText(.array([.string("git"), .string("status")])), "git status")
    }

    func testNotifyInstaller() {
        guard case let .installed(text) = CodexNotify.installing(into: "model = \"o4\"\n[profiles.x]\nnotify = \"in table\"\n", helperPath: "/A/espazio-hook") else {
            return XCTFail("expected install")
        }
        XCTAssertTrue(text.hasPrefix("notify = [\"/A/espazio-hook\", \"codex-notify\"]"))
        XCTAssertEqual(CodexNotify.installing(into: text, helperPath: "/A/espazio-hook"), .alreadyInstalled)
        XCTAssertEqual(CodexNotify.installing(into: "notify = [\"terminal-notifier\"]\n", helperPath: "/A/espazio-hook"), .conflict)
    }

    func testNotifyPayload() {
        let events = CodexNotify.events(fromPayload: #"{"type":"agent-turn-complete","thread-id":"t1","turn-id":"u","cwd":"/p","input-messages":["x"],"last-assistant-message":"Fini"}"#)
        XCTAssertEqual(events, [
            .sessionStarted(sessionID: "t1", provider: .codex, projectPath: "/p", control: .observeOnly, clientHint: nil),
            .turnCompleted(sessionID: "t1", provider: .codex, message: "Fini"),
        ])
        XCTAssertTrue(CodexNotify.events(fromPayload: "{}").isEmpty)
    }

    func testLocatorAugmentsPath() {
        let directories = CodexLocator.searchDirectories(home: "/Users/me", environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(directories.first, "/usr/bin")
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertEqual(directories.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testProcessTransportSplitsLines() async throws {
        let transport = try ProcessLineTransport(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"a\":1}\\n{\"b\":2}\\n'"], environment: [:])
        var lines: [String] = []
        for await line in transport.incoming { lines.append(String(decoding: line, as: UTF8.self)) }
        XCTAssertEqual(lines, [#"{"a":1}"#, #"{"b":2}"#])
    }
}
