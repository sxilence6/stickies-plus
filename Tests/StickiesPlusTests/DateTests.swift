import Foundation
import XCTest
@testable import StickiesPlusKit

/// Fixed clock: Monday 12 October 2026, Prague time.
final class DateTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        c.firstWeekday = 2
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { at(12, 14) }

    private func due(_ line: String, now: Date? = nil) -> DueDate? {
        DateParser.parse(line, now: now ?? self.now, calendar: cal)?.due
    }

    private func day(_ d: Int, _ m: Int = 10, _ y: Int = 2026, minute: Int? = nil) -> DueDate {
        DueDate(year: y, month: m, day: d, minute: minute)
    }

    func testWords() {
        XCTAssertEqual(due("send mix today"), day(12))
        XCTAssertEqual(due("send mix tomorrow"), day(13))
        XCTAssertEqual(due("send mix fri"), day(16))
        XCTAssertEqual(due("send mix Friday"), day(16))
        XCTAssertEqual(due("send mix mon"), day(12), "a weekday that is today means today")
        XCTAssertEqual(due("send mix next week"), day(19))
        XCTAssertEqual(due("send mix next fri"), day(23))
        XCTAssertEqual(due("send mix in 3 days"), day(15))
    }

    func testCzech() {
        XCTAssertEqual(due("poslat mix zítra"), day(13))
        XCTAssertEqual(due("poslat mix dnes"), day(12))
        XCTAssertEqual(due("poslat mix pátek"), day(16))
        XCTAssertEqual(due("poslat mix pá"), day(16))
        XCTAssertEqual(due("poslat mix příští týden"), day(19))
        XCTAssertNil(due("zavolat mu po"), "plain 'po' is a normal word")
    }

    func testNumbersAndMonths() {
        XCTAssertEqual(due("release 16 oct"), day(16))
        XCTAssertEqual(due("release oct 16"), day(16))
        XCTAssertEqual(due("release 16.10."), day(16))
        XCTAssertEqual(due("release 16.10"), day(16))
        XCTAssertEqual(due("release 16/10/2027"), day(16, 10, 2027))
        XCTAssertEqual(due("tax 16 mar"), day(16, 3, 2027), "closest March is next year's")
        XCTAssertEqual(due("tax 01.02"), day(1, 2, 2027))
        XCTAssertNil(due("release v 1.2"))
        XCTAssertNil(due("edit 1/2"))
        XCTAssertNil(due("track 2"))
    }

    func testTimes() {
        XCTAssertEqual(due("call anna 15:00"), day(12, minute: 900))
        XCTAssertEqual(due("call anna fri 9:30"), day(16, minute: 570))
        XCTAssertEqual(due("call anna tomorrow 3pm"), day(13, minute: 900))
    }

    func testNeedsWordsBeforeTheDate() {
        XCTAssertNil(due("fri"))
        XCTAssertNil(due("tomorrow"))
        XCTAssertNil(due("fri is the best day of the week"))
    }

    func testRepeating() {
        let daily = DateParser.parse("practice modular every day", now: now, calendar: cal)
        XCTAssertEqual(daily?.repeatRule, .daily)
        XCTAssertEqual(daily?.due, day(12))
        let weekly = DateParser.parse("post reel every mon", now: now, calendar: cal)
        XCTAssertEqual(weekly?.repeatRule, .weekly(2))
        XCTAssertEqual(weekly?.due, day(12))
        XCTAssertEqual(DateParser.parse("cvičit každou středu", now: now, calendar: cal)?.due, day(14))
        XCTAssertEqual(DateParser.parse("cvičit každý den 9:00", now: now, calendar: cal)?.due, day(12, minute: 540))
        XCTAssertEqual(daily.map { "practice modular every day".dropFirst($0.range.location) }, "every day")
    }

    func testRewriteToFixedDate() {
        let text = "send mix fri"
        let parsed = DateParser.parse(text, now: now, calendar: cal)!
        XCTAssertTrue(parsed.needsRewrite(of: text, now: now, calendar: cal))
        XCTAssertEqual(parsed.due.display(now: now, calendar: cal), "Fri 16 Oct")
        XCTAssertEqual(day(16, minute: 900).display(now: now, calendar: cal), "Fri 16 Oct 15:00")
        XCTAssertEqual(day(4, 1, 2027).display(now: now, calendar: cal), "Mon 4 Jan 2027")

        // the rewritten form reads back as the same date and needs no further rewrite
        for written in ["send mix Fri 16 Oct", "send mix Fri 16 Oct 15:00", "send mix Mon 4 Jan 2027"] {
            let again = DateParser.parse(written, now: now, calendar: cal)!
            XCTAssertFalse(again.needsRewrite(of: written, now: now, calendar: cal), written)
        }
        XCTAssertEqual(DueDate(key: day(16, minute: 900).key), day(16, minute: 900))
    }

    func testDayEndsAtTwo() {
        let lateNight = at(13, 1, 30)
        XCTAssertEqual(due("send mix today", now: lateNight), day(12), "at 1:30 it's still Monday")
        XCTAssertEqual(due("send mix tomorrow", now: lateNight), day(13))
    }

    func testGettingRed() {
        let monday = day(12)
        XCTAssertEqual(Urgency(due: monday, now: at(12, 19, 59), calendar: cal), .calm)
        XCTAssertEqual(Urgency(due: monday, now: at(12, 20), calendar: cal), .warming(0))
        XCTAssertEqual(Urgency(due: monday, now: at(12, 23), calendar: cal), .warming(0.5))
        XCTAssertEqual(Urgency(due: monday, now: at(13, 2), calendar: cal), .overdue)
        XCTAssertEqual(Urgency.lateText(due: monday, now: at(13, 10), calendar: cal), "1 day late")
        XCTAssertEqual(Urgency.lateText(due: monday, now: at(15, 10), calendar: cal), "3 days late")

        let three = day(12, minute: 900)
        XCTAssertEqual(Urgency(due: three, now: at(12, 8, 59), calendar: cal), .calm)
        XCTAssertEqual(Urgency(due: three, now: at(12, 12), calendar: cal), .warming(0.5))
        XCTAssertEqual(Urgency(due: three, now: at(12, 15), calendar: cal), .overdue)
        XCTAssertEqual(Urgency.lateText(due: three, now: at(12, 18), calendar: cal), "3 h late")
    }
}
