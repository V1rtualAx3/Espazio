import EspazioCore
import XCTest

final class QuickActionsTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testReminderCommandParsing() {
        let now = date(13, 10)
        let parsed = ReminderParser.parseCommand("+ acheter du pain demain 9h", now: now, calendar: calendar)
        XCTAssertEqual(parsed?.title, "acheter du pain")
        XCTAssertEqual(parsed?.due, date(14, 9))
        XCTAssertEqual(parsed?.hasDueTime, true)

        let atTime = ReminderParser.parseCommand("rappel: appeler Paul à 14h30", now: now, calendar: calendar)
        XCTAssertEqual(atTime?.title, "appeler Paul")
        XCTAssertEqual(atTime?.due, date(13, 14, 30))

        let past = ReminderParser.parseCommand("+ sport 8:15", now: now, calendar: calendar)
        XCTAssertEqual(past?.due, date(14, 8, 15), "time already passed today rolls to tomorrow")

        let tonight = ReminderParser.parseCommand("+ sortir le chien ce soir", now: now, calendar: calendar)
        XCTAssertEqual(tonight?.title, "sortir le chien")
        XCTAssertEqual(tonight?.due, date(13, 19))

        let dateOnly = ReminderParser.parseCommand("+ payer facture aujourd'hui", now: now, calendar: calendar)
        XCTAssertEqual(dateOnly?.due, date(13, 0))
        XCTAssertEqual(dateOnly?.hasDueTime, false)

        let plain = ReminderParser.parseCommand("+ lire le rapport", now: now, calendar: calendar)
        XCTAssertNil(plain?.due)
        XCTAssertNil(ReminderParser.parseCommand("réunion", now: now, calendar: calendar))
        XCTAssertNil(ReminderParser.parseCommand("+   ", now: now, calendar: calendar))
    }

    func testTimeParsingRejectsNonsense() {
        XCTAssertNil(ReminderParser.parse("version 2h99", now: date(13, 10), calendar: calendar).due)
        XCTAssertNil(ReminderParser.parse("ratio 25:00", now: date(13, 10), calendar: calendar).due)
    }

    func testSearchRanking() {
        let catalog = [
            QuickActionItem(id: "1", title: "Revue de sprint", symbol: "calendar", action: .openEvent(id: "e1")),
            QuickActionItem(id: "2", title: "Espazio", subtitle: "Claude Code", symbol: "terminal", action: .openSession(id: "s1")),
            QuickActionItem(id: "3", title: "Facture électricité", symbol: "envelope", action: .openMail(id: "m1")),
        ]
        let now = date(13, 10)
        XCTAssertEqual(QuickActionSearch.results(for: "esp", catalog: catalog, now: now, calendar: calendar).map(\.id), ["2"])
        XCTAssertEqual(QuickActionSearch.results(for: "electricite", catalog: catalog, now: now, calendar: calendar).map(\.id), ["3"])
        XCTAssertEqual(QuickActionSearch.results(for: "sprint", catalog: catalog, now: now, calendar: calendar).first?.id, "1")
        XCTAssertEqual(QuickActionSearch.results(for: "claude", catalog: catalog, now: now, calendar: calendar).first?.id, "2")
        XCTAssertEqual(QuickActionSearch.results(for: "", catalog: catalog, now: now, calendar: calendar).count, 3)
        let create = QuickActionSearch.results(for: "+ appeler maman demain", catalog: catalog, now: now, calendar: calendar)
        XCTAssertEqual(create.first?.id, "create-reminder")
        if case let .createReminder(title, due, _)? = create.first?.action {
            XCTAssertEqual(title, "appeler maman")
            XCTAssertEqual(due, date(14, 0))
        } else {
            XCTFail("expected create reminder action")
        }
    }
}
