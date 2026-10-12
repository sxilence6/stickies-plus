import AppKit
import XCTest
@testable import StickiesPlusKit

/// Drives the real ChecklistTextView the way the keyboard and mouse do
/// (insertText / insertNewline / deleteBackward / mouseDown), offscreen.
final class ChecklistTests: XCTestCase {
    private var window: NSWindow!
    private var tv: ChecklistTextView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        let (storage, container) = makeTextSystem(width: 300)
        tv = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: container)
        tv.ownedStorage = storage
        configureScrollingTextView(tv, height: 200)
        tv.isRichText = true
        tv.allowsUndo = true
        storage.delegate = tv
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                          backing: .buffered, defer: false)
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

    private func type(_ text: String) {
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func caret(_ location: Int) { tv.setSelectedRange(NSRange(location: location, length: 0)) }

    private var lines: [String] { tv.string.components(separatedBy: "\n") }

    /// nil = normal line, 0 = open box, > 0 = ticked, one entry per non-empty paragraph.
    private var states: [Double?] {
        let s = tv.textStorage!.string as NSString
        return s.paragraphRanges(in: NSRange(location: 0, length: s.length)).map { tv.checklistValue(at: $0) }
    }

    private func isOpen(_ value: Double?) -> Bool { value == 0 }
    private func isTicked(_ value: Double?) -> Bool { (value ?? 0) > 0 }

    private func indent(at location: Int) -> CGFloat {
        (tv.textStorage!.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
    }

    private func click(at viewPoint: NSPoint) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(viewPoint, to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        tv.mouseDown(with: event)
    }

    private func makeList(_ items: [String]) {
        tv.toggleChecklist(nil)
        for (index, item) in items.enumerated() {
            if index > 0 { tv.insertNewline(nil) }
            type(item)
        }
    }

    // MARK: tests

    func testNSStringParagraphEdges() {
        let s = "abc\n" as NSString
        XCTAssertEqual(s.paragraphRange(for: NSRange(location: 4, length: 0)).length, 0)
        XCTAssertEqual(("abc" as NSString).paragraphRange(for: NSRange(location: 3, length: 0)), NSRange(location: 0, length: 3))
    }

    func testChecklistOnEmptyNoteThenTyping() {
        tv.toggleChecklist(nil)
        XCTAssertNotNil(tv.trailingBoxRect(), "empty first line should show a box")
        type("bounce stems")
        XCTAssertEqual(lines, ["bounce stems"])
        XCTAssertTrue(isOpen(states[0]))
        XCTAssertEqual(indent(at: 0), ChecklistTextView.indent)
    }

    func testReturnMakesNextOpenBox() {
        makeList(["bounce stems", "fix kick eq", "sidechain bass"])
        XCTAssertEqual(lines, ["bounce stems", "fix kick eq", "sidechain bass"])
        XCTAssertEqual(states.count, 3)
        XCTAssertTrue(states.allSatisfy(isOpen))
    }

    func testReturnAfterTickedLineGivesOpenBox() {
        makeList(["a"])
        tv.toggleCheckbox(paragraph: tv.paragraph(at: 0))
        caret(1)
        tv.insertNewline(nil)
        type("b")
        XCTAssertTrue(isTicked(states[0]))
        XCTAssertTrue(isOpen(states[1]))
    }

    func testReturnOnEmptyBoxEndsList() {
        makeList(["a"])
        tv.insertNewline(nil)
        XCTAssertNotNil(tv.trailingBoxRect())
        tv.insertNewline(nil)   // second Return on the empty box
        XCTAssertNil(tv.typingAttributes[.checklist])
        type("plain")
        XCTAssertEqual(lines, ["a", "plain"])
        XCTAssertTrue(isOpen(states[0]))
        XCTAssertNil(states[1])
        XCTAssertEqual(indent(at: 2), 0)
    }

    func testReturnAtStartOfTickedLineKeepsItTicked() {
        makeList(["abc"])
        tv.toggleCheckbox(paragraph: tv.paragraph(at: 0))
        caret(0)
        tv.insertNewline(nil)
        XCTAssertEqual(lines, ["", "abc"])
        XCTAssertTrue(isOpen(states[0]))
        XCTAssertTrue(isTicked(states[1]))
    }

    func testBackspaceAtStartRemovesBoxFirst() {
        makeList(["a", "b"])
        caret(2)   // start of "b"
        tv.deleteBackward(nil)
        XCTAssertEqual(lines, ["a", "b"], "first backspace only removes the box")
        XCTAssertTrue(isOpen(states[0]))
        XCTAssertNil(states[1])
        XCTAssertEqual(indent(at: 2), 0)
        tv.deleteBackward(nil)
        XCTAssertEqual(lines, ["ab"], "second backspace joins the lines")
        XCTAssertTrue(isOpen(states[0]))
    }

    func testTypingAtStartOfBoxLineStaysInList() {
        makeList(["abc"])
        caret(0)
        type("x")
        XCTAssertEqual(lines, ["xabc"])
        XCTAssertTrue(isOpen(states[0]))
    }

    func testToggleOffAndOnAgainRestoresIndent() {
        makeList(["a", "b"])
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.toggleChecklist(nil)
        XCTAssertEqual(states.compactMap { $0 }.count, 0)
        XCTAssertEqual(indent(at: 0), 0)
        tv.toggleChecklist(nil)
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy(isOpen))
        XCTAssertEqual(indent(at: 2), ChecklistTextView.indent)
    }

    func testClickOnBoxTicksAndUnticks() {
        makeList(["bounce stems"])
        let box = tv.boxRect(forParagraphAt: 0)!
        click(at: NSPoint(x: box.midX, y: box.midY))
        XCTAssertTrue(isTicked(states[0]))
        XCTAssertLessThan(abs(states[0]! - Date().timeIntervalSinceReferenceDate), 5)
        click(at: NSPoint(x: box.midX, y: box.midY))
        XCTAssertTrue(isOpen(states[0]))
    }

    func testClickOnTextIsNotABox() {
        makeList(["bounce stems"])
        let box = tv.boxRect(forParagraphAt: 0)!
        XCTAssertNotNil(tv.checkboxParagraph(at: NSPoint(x: box.midX, y: box.midY)))
        XCTAssertNil(tv.checkboxParagraph(at: NSPoint(x: box.maxX + 40, y: box.midY)))
    }

    func testTickIsUndoable() {
        makeList(["a"])
        let undo = tv.undoManager!
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        tv.toggleCheckbox(paragraph: tv.paragraph(at: 0))
        undo.endUndoGrouping()
        XCTAssertTrue(isTicked(states[0]))
        undo.undo()
        XCTAssertTrue(isOpen(states[0]))
    }

    func testJoiningLinesFollowsFirstLine() {
        type("plain")
        tv.insertNewline(nil)
        tv.toggleChecklist(nil)
        type("task")
        XCTAssertNil(states[0])
        XCTAssertTrue(isOpen(states[1]))
        caret(6)              // start of "task"
        tv.deleteBackward(nil) // removes the box
        tv.deleteBackward(nil) // joins
        XCTAssertEqual(lines, ["plaintask"])
        XCTAssertNil(states[0])
    }

    func testSweepMovesOnlyExpiredLines() {
        makeList(["a", "b", "c"])
        tv.doneDelay = 50
        let now = Date().timeIntervalSinceReferenceDate
        let storage = tv.textStorage!
        storage.addAttribute(.checklist, value: NSNumber(value: now - 100), range: tv.paragraph(at: 2))   // b: expired
        storage.addAttribute(.checklist, value: NSNumber(value: now - 10), range: tv.paragraph(at: 4))    // c: still fading
        let done = tv.removeExpiredItems(now: now)
        XCTAssertEqual(done.map(\.text), ["b"])
        XCTAssertEqual(done[0].finishedAt.timeIntervalSinceReferenceDate, now - 100, accuracy: 0.001)
        XCTAssertEqual(lines, ["a", "c"])
        XCTAssertTrue(isOpen(states[0]))
        XCTAssertTrue(isTicked(states[1]))
    }

    func testSweepOfLastLineLeavesNoEmptyLine() {
        makeList(["a", "b"])
        tv.doneDelay = 50
        let now = Date().timeIntervalSinceReferenceDate
        tv.textStorage!.addAttribute(.checklist, value: NSNumber(value: now - 100), range: tv.paragraph(at: 2))
        XCTAssertEqual(tv.removeExpiredItems(now: now).map(\.text), ["b"])
        XCTAssertEqual(tv.string, "a")
    }

    func testPutBackAppendsOpenBox() {
        type("note title")
        tv.appendChecklistLine("export demo", font: ChecklistTextView.defaultFont)
        XCTAssertEqual(lines, ["note title", "export demo"])
        XCTAssertNil(states[0])
        XCTAssertTrue(isOpen(states[1]))
    }

    func testMarksSurviveRTFDRoundTrip() throws {
        type("Title")
        tv.insertNewline(nil)
        makeList(["one", "two"])
        tv.toggleCheckbox(paragraph: tv.paragraph(at: 6))
        let marks = tv.checklistMarks()
        XCTAssertEqual(marks.count, 2)

        let storage = tv.textStorage!
        let wrapper = try XCTUnwrap(storage.rtfdFileWrapper(from: NSRange(location: 0, length: storage.length),
                                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]))
        let reread = try XCTUnwrap(NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil))
        XCTAssertEqual(reread.string, storage.string)

        let (storage2, container2) = makeTextSystem(width: 300)
        let tv2 = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: container2)
        tv2.ownedStorage = storage2
        storage2.delegate = tv2
        storage2.setAttributedString(reread)
        tv2.applyMarks(marks)
        XCTAssertEqual(tv2.checklistMarks(), marks)
    }
}
