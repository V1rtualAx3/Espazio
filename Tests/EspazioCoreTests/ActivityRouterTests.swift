import EspazioCore
import XCTest

final class ActivityRouterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func item(_ source: ActivitySource, _ priority: ActivityPriority, key: String, title: String = "t", at offset: TimeInterval = 0, ttl: TimeInterval? = 10, decision: Bool = false) -> ActivityItem {
        ActivityItem(
            source: source, priority: priority, coalescingKey: key, title: title, symbol: "circle",
            createdAt: t0.addingTimeInterval(offset), expiresAt: ttl.map { t0.addingTimeInterval(offset + $0) },
            requiresDecision: decision)
    }

    func testPriorityOrderingAndMailNeverHidesAgentRequest() {
        var router = ActivityRouter()
        XCTAssertEqual(router.post(item(.agents, .p0, key: "approval:1", decision: true), now: t0), .presented)
        XCTAssertEqual(router.post(item(.mail, .p2, key: "mail", at: 1), now: t0), .queued)
        XCTAssertEqual(router.top?.coalescingKey, "approval:1")
        XCTAssertEqual(router.peekCandidate?.coalescingKey, "approval:1")
    }

    func testNewerItemOfSamePriorityComesFirst() {
        var router = ActivityRouter()
        router.post(item(.volume, .p3, key: "a"), now: t0)
        XCTAssertEqual(router.post(item(.battery, .p3, key: "b", at: 1), now: t0), .presented)
        XCTAssertEqual(router.items.map(\.coalescingKey), ["b", "a"])
    }

    func testCoalescingKeepsIdentityAndDoesNotReanimate() {
        var router = ActivityRouter()
        var first = item(.volume, .p3, key: "volume")
        first.progress = 0.2
        router.post(first, now: t0)
        var second = item(.volume, .p3, key: "volume", at: 0.1)
        second.progress = 0.3
        XCTAssertEqual(router.post(second, now: t0), .coalesced(visibleChange: true))
        XCTAssertEqual(router.items.count, 1)
        XCTAssertEqual(router.items[0].id, first.id)
        XCTAssertEqual(router.items[0].progress, 0.3)
    }

    func testDuplicateContentIsSuppressed() {
        var router = ActivityRouter()
        router.post(item(.chat, .p2, key: "chat:1", title: "Hello"), now: t0)
        XCTAssertEqual(router.post(item(.chat, .p2, key: "chat:1", title: "Hello", at: 2), now: t0), .duplicate)
    }

    func testExpiryAndNextExpiry() {
        var router = ActivityRouter()
        router.post(item(.volume, .p3, key: "v", ttl: 2), now: t0)
        router.post(item(.battery, .p3, key: "b", ttl: 5), now: t0)
        XCTAssertEqual(router.nextExpiry, t0.addingTimeInterval(2))
        let expired = router.expire(now: t0.addingTimeInterval(3))
        XCTAssertEqual(expired.map(\.coalescingKey), ["v"])
        XCTAssertEqual(router.items.map(\.coalescingKey), ["b"])
    }

    func testDecisionItemsNeverExpireNorGetEvicted() {
        var router = ActivityRouter(capacity: 2)
        router.post(item(.agents, .p0, key: "approval", ttl: 1, decision: true), now: t0)
        XCTAssertNil(router.items[0].expiresAt)
        router.post(item(.mail, .p2, key: "m1"), now: t0)
        router.post(item(.mail, .p2, key: "m2", at: 1), now: t0)
        router.post(item(.mail, .p4, key: "m3", at: 2), now: t0)
        XCTAssertEqual(router.items.count, 2)
        XCTAssertTrue(router.items.contains { $0.coalescingKey == "approval" })
        XCTAssertTrue(router.expire(now: t0.addingTimeInterval(100)).allSatisfy { !$0.requiresDecision })
    }

    func testSilentModeQueuesEverythingButKeepsDecisions() {
        var router = ActivityRouter(policy: FocusPolicy(mode: .silent))
        XCTAssertEqual(router.post(item(.agents, .p0, key: "a", decision: true), now: t0), .queued)
        XCTAssertNil(router.peekCandidate)
        XCTAssertEqual(router.pendingDecisionCount, 1)
    }

    func testMeetingContextOnlyLetsP0AndP1Peek() {
        let policy = FocusPolicy(mode: .normal, context: FocusContext(isInMeeting: true))
        var router = ActivityRouter(policy: policy)
        XCTAssertEqual(router.post(item(.volume, .p3, key: "v"), now: t0), .queued)
        XCTAssertEqual(router.post(item(.calendar, .p1, key: "c", at: 1), now: t0), .presented)
    }

    func testMutedSourceIsRejectedButDecisionsCannotBeMuted() {
        var router = ActivityRouter(policy: FocusPolicy(mutedSources: [.mail, .agents]))
        XCTAssertEqual(router.post(item(.mail, .p2, key: "m"), now: t0), .muted)
        XCTAssertEqual(router.post(item(.agents, .p0, key: "a", decision: true), now: t0), .presented)
    }

    func testAlreadyExpiredItemIsIgnored() {
        var router = ActivityRouter()
        XCTAssertEqual(router.post(item(.volume, .p3, key: "v", ttl: 1), now: t0.addingTimeInterval(5)), .duplicate)
        XCTAssertTrue(router.items.isEmpty)
    }

    func testDismissAllKeepsDecisions() {
        var router = ActivityRouter()
        router.post(item(.agents, .p0, key: "a", decision: true), now: t0)
        router.post(item(.agents, .p4, key: "status"), now: t0)
        router.dismissAll(from: .agents)
        XCTAssertEqual(router.items.map(\.coalescingKey), ["a"])
    }
}
