import AppKit
import XCTest
@testable import StickiesPlusKit

/// Writes board.png: a theme sticky and the day board built from it, Monday 22:00.
/// RENDER_DIR=/tmp/out swift test --filter RenderBoardPreview
final class RenderBoardPreview: XCTestCase {
    private final class Events: BoardEventSource {
        var list: [BoardEvent] = []
        var onChange: (() -> Void)?
        func events(on day: Date) -> [BoardEvent] { list.filter { Calendar.current.isDate($0.start, inSameDayAs: day) } }
    }

    func testRenderBoard() throws {
        guard let out = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set RENDER_DIR") }
        _ = NSApplication.shared
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString)")
        UserDefaults.standard.set(dataDir.path, forKey: "DataDir")
        defer { UserDefaults.standard.removeObject(forKey: "DataDir"); try? FileManager.default.removeItem(at: dataDir) }

        let cal = Calendar.current
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 22))!
        let clock = { monday }

        func note(_ lines: [(String, Int, Bool?, Bool)], color: StickyColor, frame: NSRect) -> StickyController {
            // (text, level, checkbox: nil = plain / false = open / true = ticked, folded)
            let text = NSMutableAttributedString()
            var marks: [ChecklistMark] = []
            for (i, line) in lines.enumerated() {
                let font = i == 0 ? NSFont(name: "Helvetica-Bold", size: 12)! : ChecklistTextView.defaultFont
                text.append(NSAttributedString(string: line.0 + (i == lines.count - 1 ? "" : "\n"),
                                               attributes: [.font: font, .foregroundColor: NSColor.black,
                                                            .paragraphStyle: ChecklistTextView.indentStyle(nil, level: line.1, checkbox: line.2 != nil)]))
                var mark = ChecklistMark(p: i)
                if let ticked = line.2 { mark.t = ticked ? monday.timeIntervalSinceReferenceDate - 3600 : 0; mark.id = newTaskID() }
                if line.1 > 0 { mark.l = line.1 }
                if line.3 { mark.f = true }
                if line.0.contains("old thing") { mark.m = 2 }
                marks.append(mark)
            }
            var meta = NoteMeta()
            meta.color = color
            meta.frame = NSStringFromRect(frame)
            meta.checklist = marks
            let c = StickyController(meta: meta, text: text)
            c.textView.now = clock
            return c
        }

        let music = note([
            ("music", 0, nil, false),
            ("send mix to anna today", 0, false, false),
            ("old thing Fri 9 Oct", 0, false, false),
            ("release EP Fri 30 Oct", 0, false, false),
            ("master", 1, true, false),
            ("artwork Tue 13 Oct", 1, false, false),
            ("upload", 1, false, false),
            ("admin", 0, nil, true),
            ("invoices", 1, false, false),
            ("contracts", 1, false, false),
            ("practice modular every day", 0, false, false),
        ], color: .yellow, frame: NSRect(x: 0, y: 0, width: 300, height: 260))
        let work = note([("Work", 0, nil, false), ("answer label email Mon 12 Oct 23:30", 0, false, false),
                          ("reel edit Mon 12 Oct", 0, true, false), ("caption ideas Wed 14 Oct", 0, false, false)],
                         color: .purple, frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let school = note([("School", 0, nil, false), ("start revising Mon 12 Oct", 0, false, false),
                          ("thesis outline Wed 14 Oct", 0, false, false), ("read chapter 3 Thu 15 Oct", 0, false, false)],
                         color: .green, frame: NSRect(x: 0, y: 0, width: 300, height: 100))

        var boardMeta = NoteMeta()
        boardMeta.isBoard = true
        boardMeta.boardOpen = ["today"]
        boardMeta.frame = NSStringFromRect(NSRect(x: 0, y: 0, width: 300, height: 360))
        let boardSticky = StickyController(meta: boardMeta, text: NSAttributedString())
        boardSticky.textView.now = clock
        let board = BoardController(sticky: boardSticky)
        board.now = clock
        board.notes = { [music, work, school] }
        let events = Events()
        events.list = [BoardEvent(title: "rehearsal", start: cal.date(bySettingHour: 19, minute: 30, second: 0, of: monday)!,
                                  end: cal.date(bySettingHour: 21, minute: 30, second: 0, of: monday)!, allDay: false),
                       BoardEvent(title: "team meeting", start: cal.date(byAdding: .hour, value: 14, to: monday)!,
                                  end: cal.date(byAdding: .hour, value: 15, to: monday)!, allDay: false)]
        board.events = events
        board.rebuild()

        func shot(_ sticky: StickyController) -> NSImage {
            sticky.window.orderFront(nil)
            sticky.window.contentView!.layoutSubtreeIfNeeded()
            sticky.textView.layoutManager!.ensureLayout(for: sticky.textView.textContainer!)
            sticky.textView.needsDisplay = true
            return sticky.window.contentView!.snapshot()!
        }
        var images: [NSImage] = [shot(boardSticky)]
        board.boardHeaderClicked("today")      // calendar on
        board.boardDayClicked("2026-10-14")    // and Wednesday picked
        images.append(shot(boardSticky))
        let gap: CGFloat = 20, w: CGFloat = 300, h: CGFloat = 360
        let sheet = NSImage(size: NSSize(width: w * 2 + gap * 3, height: h + gap * 2))
        sheet.lockFocus()
        NSColor(white: 0.15, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, image) in images.enumerated() {
            image.draw(in: NSRect(x: gap + CGFloat(i) * (w + gap), y: gap, width: w, height: h))
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent("board.png"))
        [music, work, school, boardSticky].forEach { $0.window.close() }
    }
}

/// Writes finish.png: the tick animation as a filmstrip. RENDER_DIR=/tmp swift test --filter RenderFinishPreview
final class RenderFinishPreview: XCTestCase {
    func testRenderFinish() throws {
        guard let out = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set RENDER_DIR") }
        _ = NSApplication.shared
        var clock = Date()
        let (storage, container) = makeTextSystem(width: 260)
        let tv = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 34), textContainer: container)
        tv.ownedStorage = storage
        configureScrollingTextView(tv, height: 34)
        tv.now = { clock }
        storage.delegate = tv
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        tv.typingAttributes = [.font: ChecklistTextView.defaultFont, .foregroundColor: NSColor.black]
        tv.toggleChecklist(nil)
        tv.insertText("send mix to anna", replacementRange: NSRange(location: NSNotFound, length: 0))
        let start = clock
        tv.toggleCheckbox(paragraph: tv.paragraph(at: 0))
        let moments: [TimeInterval] = [0.05, 0.2, 0.35, 0.55, 0.75, 0.83, 0.92, 1.0, 1.6]
        let frame = NSSize(width: 260, height: 34)
        let sheet = NSImage(size: NSSize(width: frame.width, height: frame.height * CGFloat(moments.count)))
        sheet.lockFocus()
        StickyColor.yellow.paper.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, t) in moments.enumerated() {
            clock = start.addingTimeInterval(t)
            let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
            tv.cacheDisplay(in: tv.bounds, to: rep)
            let image = NSImage(size: frame)
            image.addRepresentation(rep)
            image.draw(in: NSRect(x: 0, y: sheet.size.height - frame.height * CGFloat(i + 1), width: frame.width, height: frame.height))
            ("\(Int(t * 1000)) ms" as NSString).draw(at: NSPoint(x: 205, y: sheet.size.height - frame.height * CGFloat(i + 1) + 10),
                                                   withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
        }
        sheet.unlockFocus()
        let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("finish.png"))
        window.close()
    }
}

/// Writes spine.png: the board's top bar, calendar closed and open, at 4×. RENDER_DIR=/tmp swift test --filter RenderSpinePreview
final class RenderSpinePreview: XCTestCase {
    func testRenderSpine() throws {
        guard let out = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set RENDER_DIR") }
        _ = NSApplication.shared
        var meta = NoteMeta()
        meta.isBoard = true
        meta.frame = NSStringFromRect(NSRect(x: 0, y: 0, width: 300, height: 200))
        let sticky = StickyController(meta: meta, text: NSAttributedString())
        let board = BoardController(sticky: sticky)
        sticky.previewActive = true
        var shots: [NSBitmapImageRep] = []
        for _ in 0..<2 {
            let rep = sticky.spine.bitmapImageRepForCachingDisplay(in: sticky.spine.bounds)!
            sticky.spine.cacheDisplay(in: sticky.spine.bounds, to: rep)
            shots.append(rep)
            board.toggleCalendar()
        }
        let scale: CGFloat = 4, w = sticky.spine.bounds.width, h = sticky.spine.bounds.height
        let crop = NSRect(x: w - 60, y: 0, width: 60, height: h)
        let sheet = NSImage(size: NSSize(width: crop.width * scale, height: (h * scale + 10) * 2))
        sheet.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (i, rep) in shots.enumerated() {
            let image = NSImage(size: sticky.spine.bounds.size)
            image.addRepresentation(rep)
            image.draw(in: NSRect(x: 0, y: sheet.size.height - (h * scale + 10) * CGFloat(i + 1), width: crop.width * scale, height: h * scale),
                       from: crop, operation: .copy, fraction: 1)
        }
        sheet.unlockFocus()
        try NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: out).appendingPathComponent("spine.png"))
        sticky.window.close()
    }
}
