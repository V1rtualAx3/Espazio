import EspazioCore
import XCTest

final class ModelTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testMeetingLinkExtraction() {
        XCTAssertEqual(
            MeetingLinkExtractor.firstMeetingURL(in: ["Salle B", "Rejoindre : https://meet.google.com/abc-defg-hij."])?.absoluteString,
            "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(
            MeetingLinkExtractor.firstMeetingURL(in: ["https://example.com/doc https://acme.zoom.us/j/123?pwd=x"])?.host, "acme.zoom.us")
        XCTAssertNil(MeetingLinkExtractor.firstMeetingURL(in: ["https://notzoom.us.evil.com/x", "http://meet.google.com/insecure"]))
    }

    func testCalendarDeduplication() {
        let local = CalendarEvent(id: "ek1", title: "Point équipe", start: date(13, 10), end: date(13, 11), source: .eventKit, iCalUID: "UID-1@google.com")
        let localNoUID = CalendarEvent(id: "ek2", title: "Déjeuner", start: date(13, 12), end: date(13, 13), source: .eventKit)
        let googleDup = CalendarEvent(id: "g1", title: "Point équipe", start: date(13, 10), end: date(13, 11), source: .google, iCalUID: "uid-1@google.com")
        let googleSig = CalendarEvent(id: "g2", title: " déjeuner ", start: date(13, 12), end: date(13, 13), source: .google)
        let googleNew = CalendarEvent(id: "g3", title: "Revue", start: date(13, 9), end: date(13, 9, 30), source: .google)
        let merged = CalendarDeduplicator.merge(eventKit: [local, localNoUID], google: [googleDup, googleSig, googleNew])
        XCTAssertEqual(merged.map(\.id), ["g3", "ek1", "ek2"])
    }

    func testReminderGrouping() {
        let now = date(13, 15)
        let reminders = [
            ReminderItem(id: "late", title: "En retard", due: date(13, 9)),
            ReminderItem(id: "today", title: "Ce soir", due: date(13, 20)),
            ReminderItem(id: "dateOnlyToday", title: "Aujourd'hui", due: date(13, 0), hasDueTime: false),
            ReminderItem(id: "dateOnlyYesterday", title: "Hier", due: date(12, 0), hasDueTime: false),
            ReminderItem(id: "tomorrow", title: "Demain", due: date(14, 9)),
            ReminderItem(id: "done", title: "Fait", due: date(13, 8), isCompleted: true),
            ReminderItem(id: "nodue", title: "Sans date", due: nil),
        ]
        let groups = ReminderGroups.group(reminders, now: now, calendar: calendar)
        XCTAssertEqual(groups.overdue.map(\.id), ["dateOnlyYesterday", "late"])
        XCTAssertEqual(groups.today.map(\.id), ["dateOnlyToday", "today"])
    }

    func testCountdown() {
        let now = date(13, 10)
        XCTAssertEqual(CountdownFormatter.string(until: date(13, 10, 5), now: now), "Dans 5 min")
        XCTAssertEqual(CountdownFormatter.string(until: date(13, 12, 5), now: now), "Dans 2 h 05")
        XCTAssertEqual(CountdownFormatter.string(until: date(13, 13), now: now), "Dans 3 h")
        XCTAssertEqual(CountdownFormatter.string(until: date(13, 9), end: date(13, 11), now: now), "En cours")
    }

    func testNowPlayingExtrapolation() {
        let t = Date(timeIntervalSince1970: 100)
        let playing = NowPlaying(trackID: "x", title: "T", artist: "A", state: .playing, duration: 200, position: 50, positionDate: t)
        XCTAssertEqual(playing.position(at: t.addingTimeInterval(10)), 60)
        XCTAssertEqual(playing.position(at: t.addingTimeInterval(1000)), 200)
        XCTAssertEqual(playing.progress(at: t), 0.25)
        var paused = playing
        paused.state = .paused
        XCTAssertEqual(paused.position(at: t.addingTimeInterval(10)), 50)
        let unknown = NowPlaying(trackID: "y", title: "T", artist: "A", state: .playing, positionDate: t)
        XCTAssertNil(unknown.progress(at: t))
    }

    func testLiveActivitySelection() {
        let now = date(13, 10)
        var settings = LiveActivitySettings()
        let playing = NowPlaying(trackID: "t", title: "Thunderstruck", artist: "AC/DC", state: .playing, positionDate: now)
        var paused = playing
        paused.state = .paused
        let meeting = CalendarEvent(id: "e", title: "Daily", start: date(13, 10, 20), end: date(13, 10, 35), source: .eventKit)
        let later = CalendarEvent(id: "l", title: "Plus tard", start: date(13, 15), end: date(13, 16), source: .eventKit)

        XCTAssertNil(LiveActivityPlanner.select(.init(), settings: settings, now: now))
        XCTAssertEqual(LiveActivityPlanner.select(.init(nowPlaying: playing), settings: settings, now: now)?.coalescingKey, LiveActivityKey.media)
        XCTAssertNil(LiveActivityPlanner.select(.init(nowPlaying: paused), settings: settings, now: now), "paused hidden by default")
        settings.mediaWhenPaused = true
        XCTAssertEqual(LiveActivityPlanner.select(.init(nowPlaying: paused), settings: settings, now: now)?.symbol, "pause.fill")

        let withMeeting = LiveActivityInputs(nowPlaying: playing, nextEvent: meeting)
        let selected = LiveActivityPlanner.select(withMeeting, settings: settings, now: now)
        XCTAssertEqual(selected?.coalescingKey, LiveActivityKey.event, "imminent meeting beats media")
        XCTAssertEqual(selected?.subtitle, "Dans 20 min")
        XCTAssertEqual(LiveActivityPlanner.select(.init(nowPlaying: playing, nextEvent: later), settings: settings, now: now)?.coalescingKey,
                       LiveActivityKey.media, "meeting outside the lead window")
        XCTAssertEqual(LiveActivityPlanner.nextChange(.init(nextEvent: later), settings: settings, now: now), date(13, 14, 30))

        XCTAssertEqual(LiveActivityPlanner.select(.init(nextEvent: meeting, waitingAgents: 1), settings: settings, now: now)?.coalescingKey,
                       LiveActivityKey.agents, "waiting agent first")
        XCTAssertEqual(LiveActivityPlanner.select(.init(activeAgents: 2), settings: settings, now: now)?.subtitle, "2 actifs")
        XCTAssertEqual(LiveActivityPlanner.select(.init(unreadMail: 3), settings: settings, now: now)?.subtitle, "3", "mail badge on by default")
        XCTAssertEqual(LiveActivityPlanner.select(.init(unreadMail: 3, unreadChats: 2), settings: settings, now: now)?.coalescingKey,
                       LiveActivityKey.mail, "mail before chat")
        XCTAssertEqual(LiveActivityPlanner.select(.init(unreadMail: 0, unreadChats: 2), settings: settings, now: now)?.coalescingKey,
                       LiveActivityKey.chat)
        XCTAssertEqual(LiveActivityPlanner.select(.init(unreadMail: 250), settings: settings, now: now)?.subtitle, "99+")
        XCTAssertEqual(LiveActivityPlanner.select(.init(unreadMessages: 2), settings: settings, now: now)?.coalescingKey,
                       LiveActivityKey.messages)
        settings.mailBadge = false
        XCTAssertNil(LiveActivityPlanner.select(.init(unreadMail: 3), settings: settings, now: now))

        let item = LiveActivityPlanner.select(.init(nowPlaying: playing), settings: settings, now: now)
        XCTAssertEqual(item?.priority, .p4)
        XCTAssertNil(item?.expiresAt)
        var router = ActivityRouter()
        router.post(item!, now: now)
        XCTAssertEqual(router.post(LiveActivityPlanner.select(.init(nowPlaying: playing), settings: settings, now: now.addingTimeInterval(60))!, now: now), .duplicate)
    }

    func testLiveSettingsDecoding() {
        let decoded = EspazioSettings.decode(Data(#"{"live":{"eventLeadMinutes":1000,"unreadMail":false,"chatBadge":false}}"#.utf8))
        XCTAssertEqual(decoded.live.eventLeadMinutes, 240)
        XCTAssertTrue(decoded.live.mailBadge, "the former opt-in key no longer hides the badge")
        XCTAssertFalse(decoded.live.chatBadge)
        XCTAssertTrue(decoded.live.media)
    }

    func testPositionNormalization() {
        XCTAssertEqual(NowPlaying.normalizedPosition(42, duration: 292), 42)
        XCTAssertEqual(NowPlaying.normalizedPosition(130_500, duration: 292), 130.5, "milliseconds converted")
        XCTAssertNil(NowPlaying.normalizedPosition(9_999_999, duration: 292))
        XCTAssertNil(NowPlaying.normalizedPosition(-1, duration: 292))
        XCTAssertEqual(NowPlaying.normalizedPosition(10, duration: nil), 10)
    }

    func testSystemEventMapping() {
        let now = Date()
        let volume = SystemEventMapper.activity(for: .volume(level: 0.5, muted: false, device: "MacBook"), now: now)
        XCTAssertEqual(volume?.priority, .p3)
        XCTAssertEqual(volume?.coalescingKey, "volume")
        XCTAssertEqual(volume?.symbol, "speaker.wave.2.fill")

        let full = PowerStatus(level: 0.5, isCharging: true, isOnExternalPower: true, hasBattery: true)
        let unplugged = PowerStatus(level: 0.5, isCharging: false, isOnExternalPower: false, hasBattery: true)
        XCTAssertEqual(SystemEventMapper.activity(for: .power(unplugged, previous: full), now: now)?.title, "Sur batterie")

        let low = PowerStatus(level: 0.19, isCharging: false, isOnExternalPower: false, hasBattery: true)
        let critical = PowerStatus(level: 0.09, isCharging: false, isOnExternalPower: false, hasBattery: true)
        XCTAssertEqual(SystemEventMapper.activity(for: .power(low, previous: unplugged), now: now)?.title, "Batterie faible")
        XCTAssertNil(SystemEventMapper.activity(for: .power(low, previous: low), now: now), "no repeat while staying low")
        XCTAssertEqual(SystemEventMapper.activity(for: .power(critical, previous: low), now: now)?.priority, .p1)

        let desktop = PowerStatus(level: 1, isCharging: false, isOnExternalPower: true, hasBattery: false)
        XCTAssertNil(SystemEventMapper.activity(for: .power(desktop, previous: nil), now: now))
    }

    func testMailSenderName() {
        func mail(_ from: String) -> MailSummary {
            MailSummary(id: "1", threadID: "1", from: from, subject: "", snippet: "", date: nil, isUnread: true)
        }
        XCTAssertEqual(mail(#""Jane Doe" <jane@x.com>"#).senderName, "Jane Doe")
        XCTAssertEqual(mail("<jane@x.com>").senderName, "jane@x.com")
        XCTAssertEqual(mail("jane@x.com").senderName, "jane@x.com")
    }

    func testAgentSessionStore() {
        var store = AgentSessionStore(capacity: 2)
        let t = Date(timeIntervalSince1970: 0)
        store.apply(.sessionStarted(sessionID: "a", provider: .claudeCode, projectPath: "/Users/me/espazio/", control: .approvals, clientHint: "iTerm.app"), now: t)
        store.apply(.waiting(sessionID: "a", provider: .claudeCode, message: "Bash"), now: t.addingTimeInterval(1))
        store.apply(.turnCompleted(sessionID: "b", provider: .codex, message: "ok"), now: t.addingTimeInterval(2))
        XCTAssertEqual(store.ordered.map(\.id), ["a", "b"])
        XCTAssertEqual(store.sessions["a"]?.projectName, "espazio")
        XCTAssertEqual(store.sessions["a"]?.control, .approvals)
        store.apply(.activity(sessionID: "c", provider: .codex, message: nil), now: t.addingTimeInterval(3))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNil(store.sessions["b"], "least relevant session evicted")
        store.apply(.sessionEnded(sessionID: "c", provider: .codex), now: t.addingTimeInterval(4))
        store.prune(olderThan: 60, now: t.addingTimeInterval(100))
        XCTAssertEqual(Array(store.sessions.keys), ["a"])
        store.noteMetadata(sessionID: "a", provider: .claudeCode, projectPath: nil, control: .observeOnly, now: t)
        XCTAssertEqual(store.sessions["a"]?.control, .approvals, "control level never downgraded by metadata")
    }

    func testClientHintLearnedFromLaterEvents() {
        var store = AgentSessionStore()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(store.noteClientHint(sessionID: "x", hint: "/Applications/Claude.app"), "unknown session ignored")
        store.apply(.activity(sessionID: "x", provider: .claudeCode, message: nil), now: t)
        XCTAssertNil(store.sessions["x"]?.clientHint)
        XCTAssertTrue(store.noteClientHint(sessionID: "x", hint: "/Applications/Claude.app"))
        XCTAssertFalse(store.noteClientHint(sessionID: "x", hint: "/Applications/Claude.app"), "unchanged")
        XCTAssertFalse(store.noteClientHint(sessionID: "x", hint: nil))
        XCTAssertEqual(store.sessions["x"]?.clientHint, "/Applications/Claude.app")
    }
}

final class DiffTests: XCTestCase {
    func testLineDiffWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...20).map { "line \($0)" }
        newLines[9] = "line ten"
        newLines.insert("inserted", at: 15)
        let diff = DiffEngine.diff(path: "a.swift", old: old, new: newLines.joined(separator: "\n"))
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.addedCount, 2)
        XCTAssertTrue(diff.lines.contains(.init(.removed, "line 10")))
        XCTAssertTrue(diff.lines.contains(.init(.added, "line ten")))
        XCTAssertEqual(diff.lines.first, .init(.hunk, "…"), "leading unchanged lines elided")
        XCTAssertFalse(diff.lines.contains(.init(.context, "line 1")))
    }

    func testNewFileAndIdenticalText() {
        XCTAssertEqual(DiffEngine.diff(path: "n", old: "", new: "a\nb").addedCount, 2)
        XCTAssertTrue(DiffEngine.diff(path: "s", old: "same", new: "same").lines.isEmpty)
    }

    func testLargeInputsAreBounded() {
        let big = (0..<5000).map { "x\($0)" }.joined(separator: "\n")
        let diff = DiffEngine.diff(path: "big", old: big, new: "")
        XCTAssertEqual(diff.lines.count, DiffEngine.maxOutputLines)
        XCTAssertTrue(diff.truncated)
    }

    func testUnifiedDiffParsing() {
        let text = """
        diff --git a/src/a.swift b/src/a.swift
        index 1..2 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -0,0 +1 @@
        +Hello
        """
        let files = DiffEngine.parseUnified(text, fallbackPath: "?")
        XCTAssertEqual(files.map(\.path), ["src/a.swift", "README.md"])
        XCTAssertEqual(files[0].lines, [.init(.hunk, "@@ -1,3 +1,3 @@"), .init(.context, "let a = 1"), .init(.removed, "let b = 2"), .init(.added, "let b = 3")])
        XCTAssertEqual(DiffEngine.parseUnified("plain content\nsecond", fallbackPath: "f.txt").first?.addedCount, 2)
    }

    func testShortcutNames() {
        XCTAssertEqual(KeyShortcut(keyCode: 122, modifiers: [.command, .shift]).displayString, "⇧⌘F1")
        XCTAssertEqual(KeyShortcut(keyCode: 18, modifiers: [.option]).displayString, "⌥1")
    }
}

final class CompactTimeTests: XCTestCase {
    func testFormats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 0))!
        func ago(_ seconds: TimeInterval) -> String { CompactTime.string(for: now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        XCTAssertEqual(ago(20), "maintenant")
        XCTAssertEqual(ago(5 * 60), "5 min")
        XCTAssertEqual(ago(3 * 3600), "12:00")
        XCTAssertEqual(ago(20 * 3600), "hier")
        XCTAssertEqual(ago(3 * 86400), "dim.")
        XCTAssertEqual(ago(20 * 86400), "24/09")
    }
}

final class PeekTextTests: XCTestCase {
    /// The peek's text wing is about 80 pt: the shown value (subtitle) stays short.
    func testSystemEventsShowShortValues() {
        let now = Date()
        let caps = SystemEventMapper.activity(for: .capsLock(isOn: false), now: now)
        XCTAssertEqual(caps?.subtitle, "Désactivé")
        let output = SystemEventMapper.activity(for: .outputDeviceChanged(name: "AirPods Pro"), now: now)
        XCTAssertEqual(output?.subtitle, "AirPods Pro")
        XCTAssertEqual(output?.symbol, "airpodspro")
        let bluetooth = SystemEventMapper.activity(for: .bluetooth(deviceName: "Magic Keyboard", connected: true), now: now)
        XCTAssertEqual(bluetooth?.subtitle, "Magic Keyboard")
        XCTAssertEqual(bluetooth?.symbol, "keyboard")
        for item in [caps, output, bluetooth] {
            XCTAssertLessThanOrEqual(item?.subtitle?.count ?? 0, 16)
        }
    }
}

final class NotchTimerTests: XCTestCase {
    func testParsesTimerCommands() {
        XCTAssertEqual(TimerParser.parse("25 min"), .init(kind: .timer, duration: 1500))
        XCTAssertEqual(TimerParser.parse("10m"), .init(kind: .timer, duration: 600))
        XCTAssertEqual(TimerParser.parse("1h30"), .init(kind: .timer, duration: 5400))
        XCTAssertEqual(TimerParser.parse("90s"), .init(kind: .timer, duration: 90))
        XCTAssertEqual(TimerParser.parse("Minuteur 5"), .init(kind: .timer, duration: 300))
        XCTAssertEqual(TimerParser.parse("pomodoro"), .init(kind: .focus, duration: 1500))
        XCTAssertEqual(TimerParser.parse("focus 50"), .init(kind: .focus, duration: 3000))
        XCTAssertNil(TimerParser.parse("25"), "a bare number is a search, not a timer")
        XCTAssertNil(TimerParser.parse("réunion 25 min"))
        XCTAssertNil(TimerParser.parse("13h"), "beyond 12 h")
        XCTAssertNil(TimerParser.parse("0 min"))
    }

    func testQuickActionOffersTimer() {
        let results = QuickActionSearch.results(for: "pomodoro", catalog: [], now: Date())
        XCTAssertEqual(results.first?.action, .startTimer(seconds: 1500, kind: .focus))
    }

    func testFormattingAndPomodoroCycle() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TimerFormatter.remaining(until: start.addingTimeInterval(1500), now: start), "25:00")
        XCTAssertEqual(TimerFormatter.remaining(until: start.addingTimeInterval(3723), now: start), "1:02:03")
        XCTAssertEqual(TimerFormatter.duration(5400), "1 h 30")
        let focus = NotchTimer(kind: .focus, start: start, duration: 1500)
        XCTAssertEqual(focus.next(at: focus.end)?.kind, .pause)
        XCTAssertNil(NotchTimer(kind: .pause, start: start, duration: 300).next(at: start))
        let planned = LiveActivityPlanner.select(.init(nowPlaying: nil, timer: focus), settings: .init(), now: start.addingTimeInterval(10))
        XCTAssertEqual(planned?.coalescingKey, LiveActivityKey.timer)
    }

    func testClipboardHistoryKeepsFiveRecentDistinctTexts() {
        var history = ClipboardHistory()
        for text in ["a", "b", "c", "d", "e", "f", "b", "  "] { history.add(text) }
        XCTAssertEqual(history.items, ["b", "f", "e", "d", "c"])
        XCTAssertFalse(history.add(String(repeating: "x", count: ClipboardHistory.maxLength + 1)))
    }

    func testPresentingLetsOnlyDecisionsPeek() {
        var policy = FocusPolicy()
        policy.context.isPresenting = true
        XCTAssertEqual(policy.peekThreshold, .p0)
        policy.mode = .focused
        XCTAssertEqual(policy.peekThreshold, .p0)
    }

    func testTurnDurationIsTracked() {
        var store = AgentSessionStore()
        let t = Date(timeIntervalSince1970: 0)
        store.apply(.activity(sessionID: "s", provider: .claudeCode, message: nil), now: t)
        store.apply(.activity(sessionID: "s", provider: .claudeCode, message: nil), now: t.addingTimeInterval(60))
        store.apply(.turnCompleted(sessionID: "s", provider: .claudeCode, message: nil), now: t.addingTimeInterval(120))
        XCTAssertEqual(store.sessions["s"]?.turnStartedAt, t, "turn started with its first event")
        store.apply(.activity(sessionID: "s", provider: .claudeCode, message: nil), now: t.addingTimeInterval(300))
        XCTAssertEqual(store.sessions["s"]?.turnStartedAt, t.addingTimeInterval(300), "a new turn restarts the clock")
    }
}

final class ContinuousDisplayPolicyTests: XCTestCase {
    func testContinuousItemsStayDuringMeetingsButNotWhilePresenting() {
        let track = LiveActivityPlanner.select(
            .init(nowPlaying: NowPlaying(trackID: "t", title: "Dance With Me", artist: "Tones And I", album: nil, state: .playing,
                                         duration: nil, position: nil, positionDate: Date())),
            settings: .init(), now: Date())!
        let volume = ActivityItem(source: .volume, priority: .p3, coalescingKey: "volume", title: "Volume", symbol: "speaker", createdAt: Date())
        var policy = FocusPolicy()
        policy.context.isInMeeting = true
        XCTAssertTrue(policy.mayPeek(track), "the playing track stays during a meeting")
        XCTAssertFalse(policy.mayPeek(volume), "transient P3 items still wait")
        policy.context.isFullScreen = true
        XCTAssertTrue(policy.mayPeek(track))
        policy.context.isPresenting = true
        XCTAssertFalse(policy.mayPeek(track), "hidden while an audience sees the notch")
        policy.context.isPresenting = false
        policy.mode = .focused
        XCTAssertFalse(policy.mayPeek(track))
    }
}

final class FullScreenSettingTests: XCTestCase {
    func testHidingOverFullScreenIsOnEvenForFormerOptOut() {
        XCTAssertTrue(EspazioSettings.decode(Data(#"{"hideInFullScreen":false}"#.utf8)).hideOverFullScreen)
        XCTAssertFalse(EspazioSettings.decode(Data(#"{"hideOverFullScreen":false}"#.utf8)).hideOverFullScreen)
    }
}
