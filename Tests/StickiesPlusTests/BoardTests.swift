import AppKit
import XCTest
@testable import StickiesPlusKit

private final class StubEvents: BoardEventSource {
    var byDay: [Date: [BoardEvent]] = [:]
    var onChange: (() -> Void)?
    func events(on day: Date) -> [BoardEvent] { byDay[day] ?? [] }
}

/// The day board, end to end: theme stickies → board text → edits back into the stickies.
/// Clock: Monday 12 October 2026, 14:00, Prague.
final class BoardTests: XCTestCase {
    private var dir: URL!
    private var notes: [StickyController] = []
    private var board: BoardController!
    private var events = StubEvents()
    private var clock = Date()
    private var created: [String] = []
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BoardTests-\(UUID().uuidString)")
        UserDefaults.standard.set(dir.path, forKey: "DataDir")
        clock = at(12, 14)
        notes = []
        created = []
        events = StubEvents()
        var meta = NoteMeta()
        meta.isBoard = true
        let sticky = StickyController(meta: meta, text: NSAttributedString())
        configure(sticky)
        board = BoardController(sticky: sticky)
        board.notes = { [unowned self] in self.notes }
        board.createNote = { [unowned self] title in
            self.created.append(title)
            return self.addNote([title])
        }
        board.events = events
        board.now = { [unowned self] in self.clock }
        board.calendar = cal
    }

    override func tearDown() {
        notes.forEach { $0.window.close() }
        board.sticky.window.close()
        UserDefaults.standard.removeObject(forKey: "DataDir")
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func configure(_ sticky: StickyController) {
        sticky.textView.now = { [unowned self] in self.clock }
        sticky.textView.calendar = cal
    }

    /// A sticky: first line is its title, lines starting with "[] " are tasks, ">" indents.
    @discardableResult
    private func addNote(_ lines: [String]) -> StickyController {
        let text = NSMutableAttributedString()
        var marks: [ChecklistMark] = []
        for (i, raw) in lines.enumerated() {
            var line = raw
            var level = 0
            while line.hasPrefix(">") { level += 1; line.removeFirst() }
            let isTask = line.hasPrefix("[] ") || line.hasPrefix("[x] ")
            let ticked = line.hasPrefix("[x] ")
            if isTask { line = String(line.dropFirst(ticked ? 4 : 3)) }
            text.append(NSAttributedString(string: line + (i == lines.count - 1 ? "" : "\n"),
                                           attributes: [.font: ChecklistTextView.defaultFont, .foregroundColor: NSColor.black]))
            if isTask || level > 0 {
                marks.append(ChecklistMark(p: i, t: isTask ? (ticked ? clock.timeIntervalSinceReferenceDate : 0) : nil,
                                           id: isTask ? newTaskID() : nil, l: level > 0 ? level : nil))
            }
        }
        var meta = NoteMeta()
        meta.checklist = marks
        let note = StickyController(meta: meta, text: text)
        configure(note)
        notes.append(note)
        return note
    }

    private var boardText: NSTextStorage { board.textView.textStorage! }
    private var boardLines: [String] { boardText.string.components(separatedBy: "\n") }

    private func boardLine(containing text: String) -> NSRange {
        let s = boardText.string as NSString
        return s.allParagraphs.first { s.substring(with: $0).contains(text) }!
    }

    private func role(_ line: NSRange) -> String? { boardText.attribute(.boardRole, at: line.location, effectiveRange: nil) as? String }

    private func lines(of note: StickyController) -> [String] { note.textView.string.components(separatedBy: "\n") }

    // MARK: tests

    func testSectionsAndOrder() {
        addNote(["music", "[] send mix Mon 12 Oct", "[] bounce stems Tue 13 Oct", "[] fix kick Thu 15 Oct",
                 "[] release Fri 30 Oct", "[] old thing Fri 9 Oct", "[] no date here"])
        addNote(["Work", "[] answer email Mon 12 Oct 15:00"])
        var counts: (Int, Int) = (0, 0)
        board.onCounts = { counts = ($0, $1) }
        board.rebuild()

        XCTAssertEqual(boardLines, ["Monday 12 October", "", "old thing Fri 9 Oct", "answer email Mon 12 Oct 15:00", "send mix Mon 12 Oct", "",
                                    "Tomorrow 1  ·  This week 1  ·  Later 1"])
        XCTAssertEqual(role(boardLine(containing: "old thing")), "task")
        XCTAssertEqual(boardText.attribute(.boardLabel, at: boardLine(containing: "answer").location, effectiveRange: nil) as? String, "Work")
        XCTAssertEqual(counts.0, 3)
        XCTAssertEqual(counts.1, 1)

        board.boardHeaderClicked("tomorrow")
        XCTAssertTrue(boardLines.contains("bounce stems Tue 13 Oct"))
        XCTAssertEqual(board.sticky.meta.boardOpen, ["today", "tomorrow"])
    }

    func testTickAndEditOnTheBoardLandInTheSticky() {
        let note = addNote(["music", "[] send mix Mon 12 Oct"])
        board.rebuild()
        board.textView.toggleCheckbox(paragraph: boardLine(containing: "send mix"))
        XCTAssertTrue(note.textView.textStorage!.lineInfos()[1].isTicked)

        board.rebuild()
        let line = boardLine(containing: "send mix")
        board.textView.setSelectedRange(NSRange(location: line.location + "send mix".count, length: 0))
        board.textView.insertText(" to anna", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(lines(of: note)[1], "send mix to anna Mon 12 Oct")
    }

    func testTickingSubtasksOnTheBoardTicksTheParentInTheSticky() {
        let note = addNote(["music", "[] release EP Mon 12 Oct", ">[] master", ">[] artwork"])
        board.rebuild()
        XCTAssertEqual(boardLines.prefix(5), ["Monday 12 October", "", "release EP Mon 12 Oct", "master", "artwork"])
        XCTAssertEqual(boardText.attribute(.boardProgress, at: boardLine(containing: "release").location, effectiveRange: nil) as? String, "0/2")
        board.textView.toggleCheckbox(paragraph: boardLine(containing: "master"))
        board.rebuild()
        board.textView.toggleCheckbox(paragraph: boardLine(containing: "artwork"))
        XCTAssertTrue(note.textView.textStorage!.lineInfos()[1].isTicked, "both subtasks done ticks the parent in its sticky")
    }

    func testDatedSubtaskShowsAloneWithItsParentsName() {
        addNote(["music", "[] release EP Fri 30 Oct", ">[] artwork Mon 12 Oct", ">[] upload"])
        board.rebuild()
        let artwork = boardLine(containing: "artwork")
        XCTAssertEqual(boardText.attribute(.boardLabel, at: artwork.location, effectiveRange: nil) as? String, "release EP")
        XCTAssertEqual(boardLines.filter { $0.contains("artwork") }.count, 1)
        board.boardHeaderClicked("later")
        XCTAssertEqual(boardLines.suffix(5), ["Later", "release EP Fri 30 Oct", "upload", "", "Tomorrow  ·  This week"], "undated subtasks travel with the parent")
    }

    func testNewLineIsFiledInTheRandomPile() {
        let pile = addNote(["random pile", "[] something"])
        addNote(["music"])
        board.rebuild()
        let slot = (boardText.string as NSString).allParagraphs.first { role($0) == "slot" }!
        board.textView.setSelectedRange(NSRange(location: slot.location, length: 0))
        board.textView.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        board.textView.setSelectedRange(NSRange(location: 0, length: 0))   // leave the line
        flush()
        XCTAssertEqual(lines(of: pile), ["random pile", "call mom Mon 12 Oct", "something"], "filed, then sorted: dated first")
        XCTAssertTrue(boardLines.contains("call mom Mon 12 Oct"), "and it's on the board as a mirror")
        XCTAssertEqual(role(boardLine(containing: "call mom")), "task")
    }

    func testHashtagFilesInThatSticky() {
        let music = addNote(["music", "[] bounce stems"])
        addNote(["random pile"])
        board.rebuild()
        board.boardHeaderClicked("tomorrow")
        let slots = (boardText.string as NSString).allParagraphs.filter { role($0) == "slot" }
        board.textView.setSelectedRange(NSRange(location: slots[1].location, length: 0))   // Tomorrow's empty line
        board.textView.insertText("send mix #music", replacementRange: NSRange(location: NSNotFound, length: 0))
        board.textView.setSelectedRange(NSRange(location: 0, length: 0))
        flush()
        XCTAssertEqual(lines(of: music), ["music", "send mix Tue 13 Oct", "bounce stems"])
    }

    func testRandomPileIsMadeWhenMissing() {
        addNote(["music"])
        board.rebuild()
        let slot = (boardText.string as NSString).allParagraphs.first { role($0) == "slot" }!
        board.textView.setSelectedRange(NSRange(location: slot.location, length: 0))
        board.textView.insertText("buy strings", replacementRange: NSRange(location: NSNotFound, length: 0))
        board.textView.setSelectedRange(NSRange(location: 0, length: 0))
        flush()
        XCTAssertEqual(created, ["random pile"])
        XCTAssertEqual(lines(of: notes.last!), ["random pile", "buy strings Mon 12 Oct"])
    }

    func testMovingALateTaskFromTheBoard() {
        let note = addNote(["Work", "[] answer email Fri 9 Oct"])
        note.textView.commitAll()   // remembers Fri 9 Oct as its date
        board.rebuild()
        let line = boardLine(containing: "answer")
        let dateStart = line.location + "answer email ".count
        board.textView.setSelectedRange(NSRange(location: line.location, length: 0))
        board.textView.setSelectedRange(NSRange(location: dateStart, length: "Fri 9 Oct".count))
        board.textView.insertText("wed", replacementRange: NSRange(location: NSNotFound, length: 0))
        board.textView.setSelectedRange(NSRange(location: 0, length: 0))   // leave the line: date gets fixed
        flush()
        XCTAssertEqual(lines(of: note)[1], "answer email Wed 14 Oct")
        XCTAssertEqual(note.textView.textStorage!.lineInfos()[1].moved, 1)
        board.rebuild()
        XCTAssertFalse(boardLines.contains { $0.contains("answer") } && boardLines.firstIndex { $0.contains("answer") }! < 3,
                       "no longer late, so it left Today")
    }

    func testDeletingALineOnTheBoardDeletesTheTask() {
        let note = addNote(["music", "[] send mix Mon 12 Oct", "[] keep me"])
        board.rebuild()
        let line = boardLine(containing: "send mix")
        board.textView.setSelectedRange(line)
        board.textView.insertText("", replacementRange: line)
        XCTAssertEqual(lines(of: note), ["music", "keep me"])
    }

    func testCalendarEventsSitInToday() {
        addNote(["music", "[] send mix Mon 12 Oct"])
        let today = TaskClock.logicalToday(now: clock, calendar: cal)
        events.byDay[today] = [
            BoardEvent(title: "rehearsal", start: at(12, 19, 30), end: at(12, 22), allDay: false),
            BoardEvent(title: "breakfast", start: at(12, 9), end: at(12, 10), allDay: false),
            BoardEvent(title: "Anna's birthday", start: today, end: at(13, 0), allDay: true),
        ]
        board.rebuild()
        XCTAssertEqual(boardLines.prefix(6), ["Monday 12 October", "", "all day  Anna's birthday", "09:00  breakfast", "19:30  rehearsal", "send mix Mon 12 Oct"])
        XCTAssertEqual(boardText.attribute(.boardEventEnded, at: boardLine(containing: "breakfast").location, effectiveRange: nil) as? NSNumber, true)
        // events can't be typed into
        let event = boardLine(containing: "rehearsal")
        XCTAssertFalse(board.textView.shouldChangeText(in: NSRange(location: event.location + 2, length: 0), replacementString: "x"))
    }

    func testRepeatingTaskShowsEveryDay() {
        addNote(["practice", "[] modular 20 min every day", "[] post reel every wed"])
        board.rebuild()
        XCTAssertEqual(boardLines.prefix(4), ["Monday 12 October", "", "modular 20 min every day", ""])
        board.boardHeaderClicked("week")
        XCTAssertTrue(boardLines.contains("post reel every wed"))
    }
}

extension BoardTests {
    func testUnfiledLineIsFiledWhenTheBoardLosesFocus() {
        let pile = addNote(["random pile"])
        board.rebuild()
        let slot = (board.textView.textStorage!.string as NSString).allParagraphs.first {
            board.textView.textStorage!.attribute(.boardRole, at: $0.location, effectiveRange: nil) as? String == "slot"
        }!
        board.textView.setSelectedRange(NSRange(location: slot.location, length: 0))
        board.textView.insertText("water plants", replacementRange: NSRange(location: NSNotFound, length: 0))
        board.didResignKey()   // clicked away without leaving the line
        XCTAssertEqual(pile.textView.string, "random pile\nwater plants Mon 12 Oct")
        board.didResignKey()
        XCTAssertEqual(pile.textView.string, "random pile\nwater plants Mon 12 Oct", "filed once")
    }
}

extension BoardTests {
    private func attribute(_ key: NSAttributedString.Key, of text: String) -> Any? {
        boardText.attribute(key, at: boardLine(containing: text).location, effectiveRange: nil)
    }

    func testStickiesAreGroupsWithTheirNameAndColor() {
        let film = addNote(["Film", "[] shoot b-roll Mon 12 Oct", "[] finish script Mon 12 Oct 18:00"])
        film.setColor(.yellow)
        let school = addNote(["School", "[] start revising Mon 12 Oct"])
        school.setColor(.green)
        board.rebuild()
        XCTAssertEqual(boardLines.prefix(5), ["Monday 12 October", "", "finish script Mon 12 Oct 18:00", "shoot b-roll Mon 12 Oct", "start revising Mon 12 Oct"],
                       "earliest first inside a group; the group with the timed task first")
        XCTAssertEqual(attribute(.boardLabel, of: "finish script") as? String, "Film", "the sticky's name on its group's first line")
        XCTAssertNil(attribute(.boardLabel, of: "shoot b-roll"), "not on the others")
        XCTAssertEqual(attribute(.boardColor, of: "shoot b-roll") as? String, "yellow")
        XCTAssertEqual(attribute(.boardColor, of: "start revising") as? String, "green")
        let style = attribute(.paragraphStyle, of: "start revising") as? NSParagraphStyle
        XCTAssertGreaterThan(style?.paragraphSpacingBefore ?? 0, 0, "a little space before the next sticky's group")

        board.boardGroupClicked(film.meta.id.uuidString)
        XCTAssertTrue(boardLines.contains("Film  2"), "a folded group is one line")
        XCTAssertFalse(boardLines.contains { $0.hasPrefix("shoot b-roll") })
        board.boardGroupClicked(film.meta.id.uuidString)
        XCTAssertTrue(boardLines.contains("shoot b-roll Mon 12 Oct"))
    }

    func testPunchCardCountsWhatYouFinishedToday() {
        let note = addNote(["music", "[] send mix today", "[] bounce stems today", "[] fix kick today"])
        note.setColor(.purple)
        board.rebuild()
        let counter = { self.boardText.attribute(.boardCounter, at: (self.boardText.string as NSString).allParagraphs[1].location, effectiveRange: nil) as? String }
        XCTAssertEqual(counter(), "|3")
        board.textView.toggleCheckbox(paragraph: boardLine(containing: "bounce"))
        board.rebuild()
        let counterLine = (boardText.string as NSString).allParagraphs[1]
        XCTAssertEqual(boardText.attribute(.boardCounter, at: counterLine.location, effectiveRange: nil) as? String, "purple|2")
    }

    func testCalendarShowsHowMuchIsOnEachDay() {
        addNote(["music", "[] send mix Wed 14 Oct", "[] fix kick Wed 14 Oct", "[] master Fri 16 Oct"])
        board.rebuild()
        board.boardHeaderClicked("today")   // the date title opens the calendar
        XCTAssertTrue(board.sticky.meta.boardCalendar)
        let calendarLine = (boardText.string as NSString).allParagraphs.first { role($0) == "calendar" }!
        let cells = (boardText.attribute(.boardCounter, at: calendarLine.location, effectiveRange: nil) as! String).split(separator: "|")
        XCTAssertEqual(cells.count, 21, "three weeks from this Monday")
        XCTAssertEqual(cells[2], "2026-10-14;yellow,yellow;0;0", "Wednesday: two tasks")
        XCTAssertEqual(cells[4], "2026-10-16;yellow;0;0")

        board.boardDayClicked("2026-10-14")
        XCTAssertTrue(boardLines.contains("Wednesday 14 October"))
        XCTAssertEqual(boardLines.filter { $0.hasPrefix("send mix") }.count, 1, "listed once, under the calendar")
        // typing under the picked day files the task on that day
        let pile = addNote(["random pile"])
        board.rebuild()
        let slot = (boardText.string as NSString).allParagraphs.first { role($0) == "slot" }!
        board.textView.setSelectedRange(NSRange(location: slot.location, length: 0))
        board.textView.insertText("book studio", replacementRange: NSRange(location: NSNotFound, length: 0))
        board.textView.setSelectedRange(NSRange(location: 0, length: 0))
        flush()
        XCTAssertEqual(lines(of: pile), ["random pile", "book studio Wed 14 Oct"])
    }
}

extension BoardTests {
    func testCalendarButtonInTheBoardsTopBar() {
        XCTAssertEqual(board.sticky.spineParts, [.close, .calendar, .zoom, .collapse])
        XCTAssertFalse(addNote(["music"]).spineParts.contains(.calendar), "only the board has it")
        board.rebuild()
        board.sticky.perform(.calendar)
        XCTAssertTrue(board.sticky.meta.boardCalendar)
        XCTAssertTrue((boardText.string as NSString).allParagraphs.contains { role($0) == "calendar" })
        board.sticky.perform(.calendar)
        XCTAssertFalse(board.sticky.meta.boardCalendar)
    }
}
