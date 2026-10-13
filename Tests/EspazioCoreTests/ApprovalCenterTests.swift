import EspazioCore
import XCTest

final class ApprovalCenterTests: XCTestCase {
    static func request(id: String = "r1", session: String = "s1", kind: AgentRequestKind = .command, timeout: TimeInterval = 60) -> AgentRequest {
        let now = Date()
        return AgentRequest(
            id: id, sessionID: session, provider: .claudeCode, kind: kind, toolName: "Bash", summary: "rm -rf build",
            workingDirectory: "/tmp/project", detail: nil, createdAt: now, deadline: now.addingTimeInterval(timeout))
    }

    /// Waits until the center has `count` pending requests.
    func waitForPending(_ center: ApprovalCenter, count: Int) async {
        for _ in 0..<200 {
            if await center.pendingRequests.count == count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("pending count never reached \(count)")
    }

    func testAllowOnceOnlyWhenUserAllows() async {
        let center = ApprovalCenter()
        async let response = center.submit(Self.request())
        await waitForPending(center, count: 1)
        let result = await center.resolve(requestID: "r1", sessionID: "s1", response: .allowOnce)
        XCTAssertEqual(result, .applied)
        let value = await response
        XCTAssertEqual(value, .allowOnce)
        let pending = await center.pendingRequests
        XCTAssertTrue(pending.isEmpty)
    }

    func testTimeoutDenies() async {
        // Minimum timeout is clamped to 5 s; use a center whose clock says the deadline is past.
        let center = ApprovalCenter()
        let start = Date()
        async let response = center.submit(Self.request(timeout: 0))
        let value = await response
        XCTAssertEqual(value, .deny(.timeout))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), ApprovalCenter.minimumTimeout - 0.5)
    }

    func testDuplicateResolutionIsIdempotent() async {
        let center = ApprovalCenter()
        async let response = center.submit(Self.request())
        await waitForPending(center, count: 1)
        let first = await center.resolve(requestID: "r1", sessionID: "s1", response: .deny(.user))
        let second = await center.resolve(requestID: "r1", sessionID: "s1", response: .allowOnce)
        XCTAssertEqual(first, .applied)
        XCTAssertEqual(second, .alreadyResolved(.deny(.user)))
        let value = await response
        XCTAssertEqual(value, .deny(.user))
    }

    func testWrongSessionCannotResolve() async {
        let center = ApprovalCenter()
        async let response = center.submit(Self.request())
        await waitForPending(center, count: 1)
        let wrong = await center.resolve(requestID: "r1", sessionID: "other", response: .allowOnce)
        XCTAssertEqual(wrong, .sessionMismatch)
        let pending = await center.pendingRequests
        XCTAssertEqual(pending.count, 1)
        await center.resolve(requestID: "r1", sessionID: "s1", response: .deny(.user))
        let value = await response
        XCTAssertEqual(value, .deny(.user))
    }

    func testDuplicateSubmissionSharesTheSameDecision() async {
        let center = ApprovalCenter()
        async let first = center.submit(Self.request())
        async let second = center.submit(Self.request())
        await waitForPending(center, count: 1)
        await center.resolve(requestID: "r1", sessionID: "s1", response: .allowOnce)
        let values = await [first, second]
        XCTAssertEqual(values, [.allowOnce, .allowOnce])
        // A late retry gets the recorded decision immediately.
        let retry = await center.submit(Self.request())
        XCTAssertEqual(retry, .allowOnce)
    }

    func testSameIDFromAnotherSessionIsRefused() async {
        let center = ApprovalCenter()
        async let original = center.submit(Self.request())
        await waitForPending(center, count: 1)
        let intruder = await center.submit(Self.request(session: "attacker"))
        XCTAssertEqual(intruder, .deny(.cancelled))
        await center.resolve(requestID: "r1", sessionID: "s1", response: .allowOnce)
        let value = await original
        XCTAssertEqual(value, .allowOnce)
    }

    func testDisconnectCancelsSessionRequests() async {
        let center = ApprovalCenter()
        async let a = center.submit(Self.request(id: "a"))
        async let b = center.submit(Self.request(id: "b"))
        async let c = center.submit(Self.request(id: "c", session: "s2"))
        await waitForPending(center, count: 3)
        await center.cancelAll(sessionID: "s1")
        let values = await [a, b]
        XCTAssertEqual(values, [.deny(.disconnected), .deny(.disconnected)])
        let remaining = await center.pendingRequests.map(\.id)
        XCTAssertEqual(remaining, ["c"])
        await center.cancel(requestID: "c")
        let last = await c
        XCTAssertEqual(last, .deny(.cancelled))
    }

    func testResponseKindMustMatchRequestKind() async {
        let center = ApprovalCenter()
        async let command = center.submit(Self.request(id: "cmd"))
        async let question = center.submit(Self.request(id: "q", kind: .question(options: ["oui", "non"])))
        await waitForPending(center, count: 2)
        let answerOnCommand = await center.resolve(requestID: "cmd", sessionID: "s1", response: .answer("yes"))
        let allowOnQuestion = await center.resolve(requestID: "q", sessionID: "s1", response: .allowOnce)
        XCTAssertEqual(answerOnCommand, .invalidResponse)
        XCTAssertEqual(allowOnQuestion, .invalidResponse)
        await center.resolve(requestID: "q", sessionID: "s1", response: .answer("oui"))
        await center.resolve(requestID: "cmd", sessionID: "s1", response: .deny(.user))
        let values = await [command, question]
        XCTAssertEqual(values, [.deny(.user), .answer("oui")])
    }

    func testUnknownRequest() async {
        let center = ApprovalCenter()
        let result = await center.resolve(requestID: "nope", sessionID: "s1", response: .allowOnce)
        XCTAssertEqual(result, .unknownRequest)
    }

    func testUpdatesStreamPublishesSnapshots() async {
        let center = ApprovalCenter()
        let stream = await center.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        async let response = center.submit(Self.request())
        let afterSubmit = await iterator.next()
        XCTAssertEqual(afterSubmit?.map(\.id), ["r1"])
        await center.resolve(requestID: "r1", sessionID: "s1", response: .deny(.user))
        let afterResolve = await iterator.next()
        XCTAssertEqual(afterResolve?.count, 0)
        _ = await response
    }

    func testAuditContainsNoCommandText() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var events: [ApprovalAuditEvent] = []
            func append(_ event: ApprovalAuditEvent) { lock.lock(); events.append(event); lock.unlock() }
            func snapshot() -> [ApprovalAuditEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let box = Box()
        let center = ApprovalCenter(audit: { event in box.append(event) })
        async let response = center.submit(Self.request())
        await waitForPending(center, count: 1)
        await center.resolve(requestID: "r1", sessionID: "s1", response: .deny(.user))
        _ = await response
        let events = box.snapshot()
        XCTAssertEqual(events.map(\.action), [.submitted, .resolved])
        XCTAssertEqual(events.last?.outcome, "deny:user")
        XCTAssertFalse(String(describing: events).contains("rm -rf"))
    }

    func testPendingCapacityDeniesOverflow() async {
        let center = ApprovalCenter(maxPending: 1)
        async let first = center.submit(Self.request(id: "1"))
        await waitForPending(center, count: 1)
        let overflow = await center.submit(Self.request(id: "2"))
        XCTAssertEqual(overflow, .deny(.cancelled))
        await center.cancel(requestID: "1")
        _ = await first
    }
}
