import AppKit
import XCTest
@testable import StickiesPlusKit

/// What happens between two real keystrokes: queued commits run.
func flush() {
    ChecklistTextView.commitAllPending()
}

/// Dates, red, subtasks, folding and repeating, driven through the real text view.
/// Clock starts Monday 12 October 2026, 14:00, Prague.
final class TaskBehaviorTests: XCTestCase {
    private var window: NSWindow!
    private var tv: ChecklistTextView!
    private var clock = Date()
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
        clock = at(12, 14)
        let (storage, container) = makeTextSystem(width: 400)
        tv = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        tv.ownedStorage = storage
        configureScrollingTextView(tv, height: 300)
        tv.isRichText = true
        tv.allowsUndo = true
        tv.calendar = cal
        tv.now = { [unowned self] in self.clock }
        storage.delegate = tv
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.typingAttributes = [.font: ChecklistTextView.defaultFont, .foregroundColor: NSColor.black]
    }

    override func tearDown() {
        window.close()
        super.tearDown()
    }

    // MARK: helpers

    private func type(_ text: String) { tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)); flush() }
    private func caret(_ location: Int) { tv.setSelectedRange(NSRange(location: location, length: 0)); flush() }
    private var lines: [String] { tv.string.components(separatedBy: "\n") }
    private var infos: [LineInfo] { tv.textStorage!.lineInfos() }

    private func makeList(_ items: [String]) {
        tv.toggleChecklist(nil)
        for (index, item) in items.enumerated() {
            if index > 0 { tv.insertNewline(nil); flush() }
            type(item)
        }
    }

    private func lineStart(_ n: Int) -> Int { infos[n].range.location }

    private func screenColor(at index: Int) -> NSColor? {
        var range = NSRange(location: 0, length: tv.textStorage!.length)
        return tv.layoutManager(tv.layoutManager!, shouldUseTemporaryAttributes: [:], forDrawingToScreen: true,
                                atCharacterIndex: index, effectiveRange: &range)?[.foregroundColor] as? NSColor
    }

    // MARK: dates

    func testLeavingTheLineFixesTheDate() {
        makeList(["send mix fri", "next"])
        XCTAssertEqual(lines, ["send mix Fri 16 Oct", "next"], "Return moved the caret off the first line")
        let due = tv.textStorage!.attribute(.taskDue, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(due, "2026-10-16")
        let dateFont = tv.textStorage!.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        XCTAssertEqual(dateFont?.pointSize, 10, "the date is written small")
    }

    func testWordsInCzechToo() {
        makeList(["poslat mix zítra", "x"])
        XCTAssertEqual(lines[0], "poslat mix Tue 13 Oct")
    }

    func testMovingALateTaskCountsTheMove() {
        makeList(["answer email mon", "x"])
        XCTAssertEqual(lines[0], "answer email Mon 12 Oct")
        clock = at(14, 10)   // Wednesday: two days late
        XCTAssertEqual(Urgency(due: DueDate(year: 2026, month: 10, day: 12), now: clock, calendar: cal), .overdue)

        // retype the date
        let content = tv.textStorage!.string as NSString
        let dateStart = content.range(of: "Mon 12 Oct").location
        tv.setSelectedRange(NSRange(location: dateStart, length: "Mon 12 Oct".count))
        type("fri")
        caret(tv.textStorage!.length)   // leave the line
        XCTAssertEqual(lines[0], "answer email Fri 16 Oct")
        XCTAssertEqual(infos[0].moved, 1)

        // moving a task that isn't late doesn't count
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "Fri 16 Oct").location, length: "Fri 16 Oct".count))
        type("sat")
        caret(tv.textStorage!.length)
        XCTAssertEqual(infos[0].moved, 1)
    }

    func testRepeatingWordsAreNotRewritten() {
        makeList(["practice every day", "x"])
        XCTAssertEqual(lines[0], "practice every day")
    }

    // MARK: red

    func testWarmsUpThenTurnsRed() {
        makeList(["send mix today", "x"])
        XCTAssertNil(screenColor(at: 0), "calm at 14:00")
        clock = at(12, 23)
        let warm = screenColor(at: 0)?.usingColorSpace(.sRGB)
        XCTAssertNotNil(warm)
        XCTAssertGreaterThan(warm!.redComponent, 0.8, "orange-red by 23:00")
        clock = at(13, 3)
        let red = screenColor(at: 0)?.usingColorSpace(.sRGB)
        XCTAssertEqual(red?.redComponent ?? 0, 0.85, accuracy: 0.02)
        XCTAssertLessThan(red?.greenComponent ?? 1, 0.2)
        let dateIndex = (tv.string as NSString).range(of: "Mon 12 Oct").location
        XCTAssertLessThan(screenColor(at: dateIndex)?.alphaComponent ?? 1, 0.6, "the date itself stays faded")
    }

    // MARK: subtasks

    func testTabMakesSubtasksAndTheyTickTheParent() {
        makeList(["release EP", "master", "artwork"])
        caret(lineStart(1))
        tv.insertTab(nil)
        caret(lineStart(2))
        tv.insertTab(nil)
        XCTAssertEqual(infos.map(\.level), [0, 1, 1])
        let style = tv.textStorage!.attribute(.paragraphStyle, at: lineStart(1), effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent, ChecklistTextView.indent * 2)

        tv.toggleCheckbox(paragraph: infos[1].range)
        XCTAssertFalse(infos[0].isTicked)
        tv.toggleCheckbox(paragraph: infos[2].range)
        XCTAssertTrue(infos[0].isTicked, "last subtask done ticks the parent")
        tv.toggleCheckbox(paragraph: infos[2].range)
        XCTAssertFalse(infos[0].isTicked, "unticking a subtask unticks the parent")
        tv.toggleCheckbox(paragraph: infos[0].range)
        XCTAssertTrue(infos.allSatisfy(\.isTicked), "ticking the parent ticks every subtask")
    }

    func testIndentIsAtMostOneDeeperAndShiftTabUndoes() {
        makeList(["a", "b"])
        caret(lineStart(1))
        tv.insertTab(nil)
        tv.insertTab(nil)
        XCTAssertEqual(infos[1].level, 1)
        tv.insertBacktab(nil)
        XCTAssertEqual(infos[1].level, 0)
    }

    func testReturnOnEmptySubtaskStepsOut() {
        makeList(["a", "b"])
        tv.insertTab(nil)
        tv.insertNewline(nil)
        XCTAssertEqual((tv.typingAttributes[.taskLevel] as? NSNumber)?.intValue, 1)
        tv.insertNewline(nil)
        XCTAssertEqual((tv.typingAttributes[.taskLevel] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertNotNil(tv.typingAttributes[.checklist], "still a checkbox one level up")
    }

    // MARK: folding

    func testFoldHidesSubtasksAndReturnGoesBelowThem() {
        makeList(["mixing", "bounce stems", "fix kick eq", "admin"])
        caret(lineStart(1)); tv.insertTab(nil)
        caret(lineStart(2)); tv.insertTab(nil)
        let layout = tv.layoutManager!
        layout.ensureLayout(for: tv.textContainer!)
        let fullHeight = layout.usedRect(for: tv.textContainer!).height

        tv.toggleFold(paragraph: infos[0].range)
        layout.ensureLayout(for: tv.textContainer!)
        XCTAssertTrue(infos[0].folded)
        XCTAssertTrue(tv.isHidden(lineStart(1)))
        XCTAssertTrue(tv.isHidden(lineStart(2)))
        XCTAssertFalse(tv.isHidden(lineStart(3)))
        XCTAssertLessThan(layout.usedRect(for: tv.textContainer!).height, fullHeight - 20, "two lines folded away")

        // the caret can't land in folded text
        caret(lineStart(1) + 2)
        XCTAssertFalse(tv.isHidden(tv.selectedRange().location) && tv.selectedRange().location != tv.hiddenRanges[0].location)

        // Return at the end of the folded line adds the new line after its subtasks
        caret(NSMaxRange(infos[0].content))
        tv.insertNewline(nil)
        type("new")
        XCTAssertEqual(lines, ["mixing", "bounce stems", "fix kick eq", "new", "admin"])
        XCTAssertEqual(infos[3].level, 0)
        XCTAssertTrue(infos[3].isTask)

        tv.toggleFold(paragraph: infos[0].range)
        XCTAssertTrue(tv.hiddenRanges.isEmpty)
    }

    func testEverythingSurvivesSaving() {
        makeList(["release EP fri", "master"])
        caret(lineStart(1)); tv.insertTab(nil)
        tv.toggleFold(paragraph: infos[0].range)
        caret(0); caret(tv.textStorage!.length)
        let marks = tv.checklistMarks()
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].f, true)
        XCTAssertEqual(marks[0].d, "2026-10-16")
        XCTAssertEqual(marks[1].l, 1)

        let storage = tv.textStorage!
        let copy = NSAttributedString(rtfdFileWrapper: storage.rtfdFileWrapper(
            from: NSRange(location: 0, length: storage.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])!, documentAttributes: nil)!
        let (storage2, container2) = makeTextSystem(width: 400)
        let tv2 = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container2)
        tv2.ownedStorage = storage2
        storage2.delegate = tv2
        storage2.setAttributedString(copy)
        tv2.applyMarks(marks)
        XCTAssertEqual(tv2.checklistMarks(), marks)
        XCTAssertFalse(tv2.hiddenRanges.isEmpty, "still folded after reload")
    }

    // MARK: repeating

    func testRepeatingTaskComesBackNextDay() {
        makeList(["practice every day", "x"])
        tv.toggleCheckbox(paragraph: infos[0].range)
        clock = at(13, 1)    // still Monday's day
        XCTAssertTrue(tv.removeExpiredItems(now: clock.timeIntervalSinceReferenceDate).isEmpty)
        clock = at(13, 2, 1) // Monday is over
        let done = tv.removeExpiredItems(now: clock.timeIntervalSinceReferenceDate)
        XCTAssertEqual(done.map(\.text), ["practice"])
        XCTAssertEqual(lines[0], "practice every day")
        XCTAssertFalse(infos[0].isTicked, "fresh again")
    }

    func testDonePileTextLeavesOutTheDate() {
        makeList(["send mix fri", "x"])
        tv.toggleCheckbox(paragraph: infos[0].range)
        tv.doneDelay = 60
        clock = clock.addingTimeInterval(120)
        XCTAssertEqual(tv.removeExpiredItems(now: clock.timeIntervalSinceReferenceDate).map(\.text), ["send mix"])
    }

    // MARK: sorting by date

    func testDatedTasksSortThemselvesWithinTheirBlock() {
        type("Film Update")
        tv.insertNewline(nil); flush()
        makeList(["shoot b-roll", "trailer cut wed", "finish script mon"])
        tv.insertNewline(nil); flush()
        tv.insertNewline(nil); flush()          // leaves the list
        type("Ideas")
        XCTAssertEqual(lines, ["Film Update", "finish script Mon 12 Oct", "trailer cut Wed 14 Oct", "shoot b-roll", "Ideas"],
                       "dated first by date, undated after, the heading lines stay where they are")
    }

    func testSubtasksMoveWithTheirParentAndTheCaretStays() {
        makeList(["later thing fri", "soon thing", "sub of soon"])
        caret(lineStart(2)); tv.insertTab(nil)  // "sub of soon" under "soon thing"
        XCTAssertEqual(lines, ["later thing Fri 16 Oct", "soon thing", "sub of soon"], "undated stays below dated")
        caret(NSMaxRange(infos[1].content))
        type(" mon")                            // give "soon thing" a date...
        caret(lineStart(2) + 2)                 // ...and leave the line
        XCTAssertEqual(lines, ["soon thing Mon 12 Oct", "sub of soon", "later thing Fri 16 Oct"])
        XCTAssertEqual(infos[1].level, 1)
        let s = tv.string as NSString
        XCTAssertEqual(tv.selectedRange().location, s.range(of: "sub of soon").location + 2, "the caret stayed on its line")
    }
}
