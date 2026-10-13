import EspazioCore
import XCTest

final class SupportTests: XCTestCase {
    func testBackoffGrowsAndIsCapped() {
        let backoff = ExponentialBackoff(base: 2, maximum: 60, jitter: 0)
        XCTAssertEqual(backoff.delay(attempt: 0), 2)
        XCTAssertEqual(backoff.delay(attempt: 3), 16)
        XCTAssertEqual(backoff.delay(attempt: 30), 60)
        let jittered = ExponentialBackoff(base: 10, maximum: 100, jitter: 0.5)
        XCTAssertEqual(jittered.delay(attempt: 0, random: 0), 5)
        XCTAssertEqual(jittered.delay(attempt: 0, random: 1), 15)
    }

    func testTokenBucket() {
        let start = Date(timeIntervalSince1970: 0)
        var bucket = TokenBucket(capacity: 2, refillRate: 1, now: start)
        XCTAssertTrue(bucket.tryConsume(now: start))
        XCTAssertTrue(bucket.tryConsume(now: start))
        XCTAssertFalse(bucket.tryConsume(now: start))
        XCTAssertEqual(bucket.waitTime(now: start), 1, accuracy: 0.001)
        XCTAssertTrue(bucket.tryConsume(now: start.addingTimeInterval(1)))
    }

    func testBoundedCacheEvictsLeastRecentlyUsed() {
        var cache = BoundedCache<String, Int>(countLimit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c")
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.count, 2)
    }

    func testBoundedCacheCostLimit() {
        var cache = BoundedCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, for: "a", cost: 60)
        cache.insert(2, for: "b", cost: 60)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.totalCost, 60)
        cache.insert(3, for: "huge", cost: 500)
        XCTAssertNil(cache.value(for: "huge"))
    }

    func testRedactor() {
        let input = #"Authorization: Bearer ya29.a0AfH6SMB access_token=abc123 key sk-ant-REDACTEDREDACTEDxx {"refresh_token": "1//0gXYZ"} ghp_abcdefghijklmnopqrstuvwxyz"#
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("ya29"))
        XCTAssertFalse(output.contains("abc123"))
        XCTAssertFalse(output.contains("sk-ant"))
        XCTAssertFalse(output.contains("1//0gXYZ"))
        XCTAssertFalse(output.contains("ghp_"))
        XCTAssertTrue(output.contains("access_token=[REDACTED]"))
        XCTAssertEqual(Redactor.redact("git status"), "git status")
    }

    func testTruncate() {
        XCTAssertEqual(Redactor.truncate("abcdef", limit: 4), "abc…")
        XCTAssertEqual(Redactor.truncate("abc", limit: 4), "abc")
    }

    func testAuditLogWritesNoSecretsAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("audit.log")
        let log = AuditLog(fileURL: url, maxBytes: 400)
        for index in 0..<5 {
            log.record(ApprovalAuditEvent(
                action: .resolved, requestID: "r\(index)", sessionID: "s", provider: .codex, toolName: "Bearer secretvalue",
                outcome: "deny:user", date: Date(timeIntervalSince1970: 0)))
        }
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("secretvalue"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testJSONValueRoundTrip() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(value["b"]?["c"]?.stringValue, "d")
        XCTAssertEqual(value.compactString(), text)
    }

    func testSettingsDecodingIsTolerant() {
        let partial = #"{"displayMode":"allScreens","googleSyncInterval":5,"unknownKey":true,"modules":{"gmail":true},"focusMode":"bogus"}"#
        let settings = EspazioSettings.decode(Data(partial.utf8))
        XCTAssertEqual(settings.displayMode, .allScreens)
        XCTAssertEqual(settings.googleSyncInterval, 60)
        XCTAssertTrue(settings.modules.gmail)
        XCTAssertTrue(settings.modules.media)
        XCTAssertEqual(settings.focusMode, .normal)
        XCTAssertEqual(EspazioSettings.decode(Data("garbage".utf8)), EspazioSettings())
        XCTAssertEqual(EspazioSettings.decode(settings.encoded()), settings)
        XCTAssertFalse(settings.hasCompletedOnboarding, "welcome shown once for existing settings files")
    }

    func testMutedSources() {
        var modules = ModuleSettings()
        XCTAssertTrue(modules.mutedSources.contains(.mail))
        modules.gmail = true
        modules.battery = false
        XCTAssertFalse(modules.mutedSources.contains(.mail))
        XCTAssertTrue(modules.mutedSources.isSuperset(of: [.battery, .power]))
    }

    func testShortcutDisplayAndValidity() {
        XCTAssertEqual(KeyShortcut.defaultQuickActions.displayString, "⌃⌥Espace")
        XCTAssertFalse(KeyShortcut(keyCode: 0, modifiers: [.shift]).isValid)
    }
}
