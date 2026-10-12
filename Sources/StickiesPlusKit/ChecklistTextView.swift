import AppKit

/// A TextKit 1 text system. The caller keeps the returned storage alive
/// (a text view doesn't own a storage it didn't create).
func makeTextSystem(width: CGFloat) -> (NSTextStorage, NSTextContainer) {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    return (storage, container)
}

func configureScrollingTextView(_ view: NSTextView, height: CGFloat) {
    view.minSize = NSSize(width: 0, height: height)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 6, height: 6)   // measured against Stickies
}

/// The day board listens to its text view through this.
protocol BoardTextDelegate: AnyObject {
    func boardHeaderClicked(_ section: String)
    /// A sticky's name (or its folded group line) was clicked: fold or unfold its group.
    func boardGroupClicked(_ group: String)
    /// A day in the calendar grid was clicked ("2026-10-15").
    func boardDayClicked(_ day: String)
    /// The caret left a line typed on the board: file every typed line except the one at `caretLine`.
    func boardFileTypedLines(except caretLine: NSRange)
    /// The caret moved to another line (a good moment to refresh the board).
    func boardCaretChangedLine()
}

/// The note's text view: Stickies' rich text plus checkboxes, subtasks, folding and dates.
/// All line state lives in paragraph attributes (see TaskText.swift). Boxes, arrows,
/// strike-through, red warming and the little labels at line ends are drawn on top
/// and never touch the stored text.
final class ChecklistTextView: NSTextView, NSTextStorageDelegate, NSLayoutManagerDelegate, NSViewToolTipOwner {
    static let indent: CGFloat = 18
    static let boxSize: CGFloat = 11
    static var defaultFont: NSFont { NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12) }
    static var smallFont: NSFont { NSFont(name: "Helvetica", size: 10) ?? .systemFont(ofSize: 10) }

    var ownedStorage: NSTextStorage? {
        didSet { layoutManager?.delegate = self }   // colors and folding are decided at draw time
    }
    var palette: StickyColor = .yellow {
        didSet {
            insertionPointColor = palette.text
            selectedTextAttributes = palette.isDark
                ? [.backgroundColor: NSColor(white: 1, alpha: 0.25)]
                : [.backgroundColor: NSColor.selectedTextBackgroundColor]
            needsDisplay = true
        }
    }
    var doneDelay: TimeInterval = 13 * 3600
    var now: () -> Date = { Date() }
    var calendar = Calendar.current
    weak var boardDelegate: BoardTextDelegate?
    var isBoard: Bool { boardDelegate != nil }

    /// The empty last line has no characters to carry attributes, so its checkbox
    /// lives in the typing attributes until the user types.
    private var keepTrailingChecklist = false
    private var refreshQueued = false
    private var relayoutQueued = false
    private(set) var hiddenRanges: [NSRange] = []
    private var hoveredLine: Int?
    private var lastLineLocation: Int?
    private var lastLineID: String?
    private var isCommitting = false
    private var pendingCommitIDs: [String] = []
    private var pendingBoardFiling = false
    private var commitScheduled = false
    private var dateCache: [String: TaskDate?] = [:]
    private var dateCacheDay: Date?
    private var hoverArea: NSTrackingArea?

    /// The finish animation: a strike line drawn in a few uneven steps, then a pixel sparkle.
    private struct Finish {
        var start: Date
        var strikeTimes: [TimeInterval]   // when each strike step lands
        var sparks: [(dx: CGFloat, dy: CGFloat, light: Bool)]
        var sparkStart: TimeInterval { strikeTimes.last ?? 0 }
        var end: TimeInterval { sparkStart + Double(ChecklistTextView.sparkFrames.count) * 0.085 + 0.12 }
    }
    static let strikeSteps: [CGFloat] = [0.12, 0.27, 0.36, 0.55, 0.63, 0.81, 0.9, 1]
    static let sparkFrames: [CGFloat] = [0.35, 0.7, 1, 1.15]
    private var finishing: [String: Finish] = [:]   // task id → animation
    private var punch: (index: Int, start: Date)?   // the newest hole on the board's punch card
    private var lastPunched = -1
    private var animationTimer: Timer?

    private var storage: NSTextStorage { textStorage! }
    private var text: NSString { storage.string as NSString }

    // MARK: Reading lines

    func paragraph(at location: Int) -> NSRange {
        text.paragraphRange(for: NSRange(location: location, length: 0))
    }

    /// nil = normal line, 0 = open checkbox, > 0 = ticked at that time.
    func checklistValue(at paragraph: NSRange) -> Double? {
        if paragraph.length == 0 { return (typingAttributes[.checklist] as? NSNumber)?.doubleValue }
        return (storage.attribute(.checklist, at: paragraph.location, effectiveRange: nil) as? NSNumber)?.doubleValue
    }

    func lineInfo(_ paragraph: NSRange) -> LineInfo { storage.lineInfo(for: paragraph, in: text) }

    private func attribute(_ key: NSAttributedString.Key, of paragraph: NSRange) -> Any? {
        paragraph.length == 0 ? typingAttributes[key] : storage.attribute(key, at: paragraph.location, effectiveRange: nil)
    }

    func level(of paragraph: NSRange) -> Int { (attribute(.taskLevel, of: paragraph) as? NSNumber)?.intValue ?? 0 }

    func role(of paragraph: NSRange) -> String? { paragraph.length == 0 ? nil : attribute(.boardRole, of: paragraph) as? String }

    /// The date at the end of a task line, read from its text.
    func taskDate(of paragraph: NSRange) -> TaskDate? {
        let content = text.substring(with: text.contentRange(of: paragraph))
        let today = TaskClock.logicalToday(now: now(), calendar: calendar)
        if dateCacheDay != today { dateCache.removeAll(); dateCacheDay = today }
        if let cached = dateCache[content] { return cached }
        let parsed = DateParser.parse(content, now: now(), calendar: calendar)
        dateCache[content] = parsed
        return parsed
    }

    func taskRange(id: String) -> NSRange? {
        text.allParagraphs.first { storage.attribute(.taskID, at: $0.location, effectiveRange: nil) as? String == id }
    }

    // MARK: Saving

    func checklistMarks() -> [ChecklistMark] {
        storage.lineInfos().enumerated().compactMap { index, line in
            var mark = ChecklistMark(p: index)
            mark.t = line.checklist
            mark.id = line.id
            mark.l = line.level > 0 ? line.level : nil
            mark.f = line.folded ? true : nil
            mark.d = storage.attribute(.taskDue, at: line.range.location, effectiveRange: nil) as? String
            mark.m = line.moved > 0 ? line.moved : nil
            return mark.isEmpty ? nil : mark
        }
    }

    func applyMarks(_ marks: [ChecklistMark]) {
        let paragraphs = text.allParagraphs
        storage.beginEditing()
        for mark in marks where mark.p < paragraphs.count {
            let p = paragraphs[mark.p]
            func set(_ key: NSAttributedString.Key, _ value: Any?) { if let value { storage.addAttribute(key, value: value, range: p) } }
            set(.checklist, mark.t.map { NSNumber(value: $0) })
            set(.taskID, mark.t == nil ? nil : (mark.id ?? newTaskID()))
            set(.taskLevel, mark.l.map { NSNumber(value: $0) })
            set(.taskFolded, mark.f == true ? NSNumber(value: true) : nil)
            set(.taskDue, mark.d)
            set(.taskMoved, mark.m.map { NSNumber(value: $0) })
        }
        storage.endEditing()
        applyHiddenRanges(computeHiddenRanges())
        refreshCheckedAppearance()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // NSTextView leaves drawing clipped to the text area; the arrows and color bars live in the margin
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dirtyRect).setClip()
        drawDecorations(in: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDecorations(in dirtyRect: NSRect) {
        guard let layout = layoutManager, let container = textContainer else { return }
        let lines = storage.lineInfos()
        let date = now()
        if !lines.isEmpty {
            let origin = textContainerOrigin
            let glyphs = layout.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -20), in: container)
            let visible = text.paragraphRange(for: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            for (index, line) in lines.enumerated()
            where NSIntersectionRange(line.range, visible).length > 0 && !isHidden(line.range.location) {
                drawLine(index, line, lines: lines, now: date)
            }
        }
        if let box = trailingBoxRect(), let value = (typingAttributes[.checklist] as? NSNumber)?.doubleValue {
            drawBox(box, checked: value > 0, color: palette.control, faint: false)
        }
    }

    private func drawLine(_ index: Int, _ line: LineInfo, lines: [LineInfo], now: Date) {
        let role = role(of: line.range)
        let hasChildren = !descendants(of: index, in: lines).isEmpty
        if let sticky = boardColor(of: line.range) { drawColorBar(sticky, for: line) }
        switch role {
        case "counter"?: drawPunchCard(line); return
        case "calendar"?: drawCalendar(line, now: now); return
        case "group"?:
            if let arrow = arrowRect(for: line) { drawArrow(arrow, folded: true) }
            return
        default: break
        }
        if let role, role.hasPrefix("header:") {
            if role.hasPrefix("header:day:"), let arrow = arrowRect(for: line) {
                drawArrow(arrow, folded: false)
            } else if role != "header:today", let arrow = arrowRect(for: line) {
                drawArrow(arrow, folded: line.folded)
            }
            return
        }
        if hasChildren, line.folded || hoveredLine == line.range.location, let arrow = arrowRect(for: line) {
            drawArrow(arrow, folded: line.folded)
        }
        var labels: [(String, NSColor)] = []
        if line.isTask, let box = boxRect(forParagraphAt: line.range.location) {
            let date = line.isTicked ? nil : taskDate(of: line.range)
            let urgency = date.map { Urgency(due: $0.due, now: now, calendar: calendar) } ?? .calm
            if line.isTicked {
                let finish = line.id.flatMap { finishing[$0] }
                let elapsed = finish.map { now.timeIntervalSince($0.start) } ?? .infinity
                let fraction = finish.map { f in
                    zip(Self.strikeSteps, f.strikeTimes).filter { $0.1 <= elapsed }.last?.0 ?? 0
                } ?? 1
                drawStrike(paragraph: line.range, color: fadedColor(tickedAt: line.checklist!, now: now), fraction: fraction)
                if let finish, elapsed >= finish.sparkStart, elapsed < finish.end {
                    drawSparks(finish, elapsed: elapsed, line: line, sticky: boardColor(of: line.range))
                }
            }
            drawBox(box, checked: line.isTicked, color: urgencyColor(urgency) ?? palette.control, faint: role == "slot")

            if let progress = attribute(.boardProgress, of: line.range) as? String {
                labels.append((progress, palette.text.withAlphaComponent(0.45)))
            } else {
                let kids = directChildren(of: index, in: lines).filter { lines[$0].isTask }
                if !kids.isEmpty {
                    labels.append(("\(kids.filter { lines[$0].isTicked }.count)/\(kids.count)", palette.text.withAlphaComponent(0.45)))
                }
            }
            if let date, urgency == .overdue, date.repeatRule == nil {
                labels.append((Urgency.lateText(due: date.due, now: now, calendar: calendar), redColor))
            }
            if line.moved > 0, !line.isTicked {
                labels.append(("moved \(line.moved)×", redColor.withAlphaComponent(0.6)))
            }
        }
        if line.folded, hasChildren {
            labels.append(("+\(descendants(of: index, in: lines).count)", palette.text.withAlphaComponent(0.4)))
        }
        drawLabels(labels, after: line)
        if let label = attribute(.boardLabel, of: line.range) as? String {
            drawRightLabel(label, on: line, color: boardColor(of: line.range).map(Self.labelColor) ?? palette.text.withAlphaComponent(0.4))
        }
    }

    // MARK: Board pieces

    private func boardColor(of paragraph: NSRange) -> StickyColor? {
        guard isBoard, paragraph.length > 0, let raw = attribute(.boardColor, of: paragraph) as? String else { return nil }
        return StickyColor(rawValue: raw)
    }

    /// A sticky's name in its own color, dark enough to read on any paper.
    static func labelColor(_ sticky: StickyColor) -> NSColor {
        sticky.highlight.blended(withFraction: 0.3, of: .black) ?? sticky.highlight
    }

    /// The line's vertical extent in view coordinates, without the space above it.
    private func lineSpan(_ line: LineInfo) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let layout = layoutManager, line.range.location < storage.length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
            top = min(top, used.minY)
            bottom = max(bottom, rect.maxY)
        }
        guard top < bottom else { return nil }
        return (top + textContainerOrigin.y, bottom + textContainerOrigin.y)
    }

    /// A thin bar in the sticky's color at the board's left edge; one sticky's lines join into one bar.
    private func drawColorBar(_ sticky: StickyColor, for line: LineInfo) {
        guard let span = lineSpan(line) else { return }
        sticky.control.setFill()
        NSRect(x: 0, y: span.minY, width: 3, height: span.maxY - span.minY).fill()
    }

    /// The punch card: "purple,yellow|3" = done (in sticky colors, in the order you finished), then open holes.
    private func drawPunchCard(_ line: LineInfo) {
        guard let raw = attribute(.boardCounter, of: line.range) as? String, let span = lineSpan(line) else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        let done = parts.first.map { $0.split(separator: ",").compactMap { StickyColor(rawValue: String($0)) } } ?? []
        let open = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let total = done.count + open
        let x0 = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
        let midY = (span.minY + span.maxY) / 2
        let font = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let quiet: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.text.withAlphaComponent(0.5)]
        guard total > 0 else {
            ("nothing on today" as NSString).draw(at: NSPoint(x: x0, y: midY - 7), withAttributes: quiet)
            return
        }
        let room = bounds.width - x0 - 50
        let step = min(14, max(6, room / CGFloat(total)))
        let size = min(9, step - 3)
        if done.count - 1 > lastPunched, lastPunched >= 0 { punch = (done.count - 1, now()); startAnimationTimer() }
        lastPunched = done.count - 1
        for i in 0..<total {
            var d = size
            if let punch, punch.index == i {
                let frame = Int(now().timeIntervalSince(punch.start) / 0.07)
                d = frame < 2 ? [size / 3, size * 2 / 3][frame] : size
            }
            let center = NSPoint(x: x0 + CGFloat(i) * step + size / 2, y: midY)
            let hole = NSBezierPath(ovalIn: NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
            if i < done.count {
                done[i].control.setFill()
                hole.fill()
            } else {
                hole.lineWidth = 1
                hole.setLineDash([2, 1.5], count: 2, phase: 0)
                palette.control.setStroke()
                hole.stroke()
            }
        }
        let label = "\(done.count)/\(total)" as NSString
        label.draw(at: NSPoint(x: x0 + CGFloat(total) * step + 4, y: midY - 7), withAttributes: quiet)
    }

    /// Three weeks from this Monday: a mark per task in its sticky's color.
    private struct CalendarCell { var key: String; var day: Date; var dots: [StickyColor]; var late: Int; var selected: Bool }

    private func calendarCells(_ line: LineInfo) -> [CalendarCell] {
        guard let raw = attribute(.boardCounter, of: line.range) as? String else { return [] }
        return raw.split(separator: "|").compactMap { cell in
            let f = cell.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let due = DueDate(key: f[0]) else { return nil }
            return CalendarCell(key: f[0], day: due.startOfDay(calendar),
                                dots: f[1].split(separator: ",").compactMap { StickyColor(rawValue: String($0)) },
                                late: Int(f[2]) ?? 0, selected: f[3] == "1")
        }
    }

    private func calendarGeometry(_ line: LineInfo) -> (origin: NSPoint, cell: NSSize)? {
        guard let span = lineSpan(line) else { return nil }
        let x0 = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
        let width = bounds.width - x0 * 2
        return (NSPoint(x: x0, y: span.minY + 14), NSSize(width: floor(width / 7), height: 30))
    }

    private func drawCalendar(_ line: LineInfo, now: Date) {
        guard let (origin, cell) = calendarGeometry(line) else { return }
        let cells = calendarCells(line)
        let today = TaskClock.logicalToday(now: now, calendar: calendar)
        let small = NSFont(name: "Helvetica", size: 9) ?? .systemFont(ofSize: 9)
        let ink = palette.text
        for (i, name) in ["M", "T", "W", "T", "F", "S", "S"].enumerated() {
            (name as NSString).draw(at: NSPoint(x: origin.x + CGFloat(i) * cell.width + 3, y: origin.y - 13),
                                    withAttributes: [.font: small, .foregroundColor: ink.withAlphaComponent(0.45)])
        }
        for (i, c) in cells.enumerated() {
            let rect = NSRect(x: origin.x + CGFloat(i % 7) * cell.width, y: origin.y + CGFloat(i / 7) * cell.height,
                              width: cell.width - 2, height: cell.height - 2)
            let past = c.day < today
            if c.selected {
                palette.spine.setFill()
                rect.fill()
            }
            let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            frame.lineWidth = 1
            (c.day == today ? palette.highlight : palette.control.withAlphaComponent(past ? 0.25 : 0.5)).setStroke()
            frame.stroke()
            let number = "\(calendar.component(.day, from: c.day))" as NSString
            number.draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1),
                        withAttributes: [.font: small, .foregroundColor: ink.withAlphaComponent(past ? 0.3 : 0.7)])
            if c.late > 0 {
                ("!\(c.late)" as NSString).draw(at: NSPoint(x: rect.maxX - 13, y: rect.minY + 1),
                                                 withAttributes: [.font: small, .foregroundColor: redColor])
            }
            // a 4 pt mark per task, in rows of four; more than eight → "+n"
            for (k, sticky) in c.dots.prefix(8).enumerated() {
                let mark = NSRect(x: rect.minX + 3 + CGFloat(k % 4) * 6, y: rect.minY + 13 + CGFloat(k / 4) * 6, width: 4, height: 4)
                sticky.control.withAlphaComponent(past ? 0.4 : 1).setFill()
                mark.fill()
            }
            if c.dots.count > 8 {
                ("+\(c.dots.count - 8)" as NSString).draw(at: NSPoint(x: rect.maxX - 14, y: rect.maxY - 11),
                                                          withAttributes: [.font: small, .foregroundColor: ink.withAlphaComponent(0.6)])
            }
        }
    }

    private func calendarDay(at point: NSPoint, line: LineInfo) -> String? {
        guard let (origin, cell) = calendarGeometry(line) else { return nil }
        let column = Int((point.x - origin.x) / cell.width), row = Int((point.y - origin.y) / cell.height)
        guard point.x >= origin.x, point.y >= origin.y, (0..<7).contains(column) else { return nil }
        let cells = calendarCells(line)
        let index = row * 7 + column
        return cells.indices.contains(index) ? cells[index].key : nil
    }

    private func rightLabelRect(_ line: LineInfo) -> NSRect? {
        guard let label = attribute(.boardLabel, of: line.range) as? String, let end = lineEnd(of: line) else { return nil }
        let size = (label as NSString).size(withAttributes: [.font: Self.smallFont])
        let x = bounds.width - textContainerInset.width - (textContainer?.lineFragmentPadding ?? 5) - size.width
        guard x > end.x + 4 else { return nil }
        return NSRect(x: x, y: end.y - Self.smallFont.ascender, width: size.width, height: size.height)
    }

    // MARK: The finish animation

    private func startFinish(id: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        var t: TimeInterval = 0
        let times = Self.strikeSteps.map { _ -> TimeInterval in t += 0.06 + Double.random(in: 0...0.04); return t }
        let sparks = (0..<7).map { k -> (dx: CGFloat, dy: CGFloat, light: Bool) in
            let angle = CGFloat.random(in: 0..<(2 * .pi)), radius = CGFloat.random(in: 6...15)
            return (cos(angle) * radius, sin(angle) * radius, k % 3 == 0)
        }
        finishing[id] = Finish(start: now(), strikeTimes: times, sparks: sparks)
        startAnimationTimer()
    }

    /// About 12 frames a second: on purpose a bit choppy, like stop-motion.
    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animationTick() }
        }
    }

    private func animationTick() {
        let date = now()
        finishing = finishing.filter { date.timeIntervalSince($0.value.start) < $0.value.end }
        if let p = punch, date.timeIntervalSince(p.start) > 0.2 { punch = nil }
        needsDisplay = true
        if finishing.isEmpty && punch == nil {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func drawSparks(_ finish: Finish, elapsed: TimeInterval, line: LineInfo, sticky: StickyColor?) {
        guard let end = lineEnd(of: line) else { return }
        let frame = min(Int((elapsed - finish.sparkStart) / 0.085), Self.sparkFrames.count - 1)
        let reach = Self.sparkFrames[frame]
        let color = (sticky ?? palette).control
        let center = NSPoint(x: end.x + 2, y: end.y - 4)
        for spark in finish.sparks {
            let alpha: CGFloat = frame == Self.sparkFrames.count - 1 ? 0.5 : 1
            (spark.light ? NSColor.white : color).withAlphaComponent(alpha).setFill()
            NSRect(x: (center.x + spark.dx * reach).rounded(), y: (center.y + spark.dy * reach).rounded(), width: 3, height: 3).fill()
        }
    }

    func boxRect(forParagraphAt location: Int) -> NSRect? {
        guard let layout = layoutManager, location < storage.length else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = layout.location(forGlyphAt: glyph).y
        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? Self.defaultFont
        return boxRect(line: line, baseline: baseline, font: font, level: level(of: paragraph(at: location)))
    }

    func trailingBoxRect() -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let length = storage.length
        let selection = selectedRange()
        guard selection.length == 0, selection.location == length, paragraph(at: length).length == 0 else { return nil }
        layout.ensureLayout(for: container)
        let line = layout.extraLineFragmentRect
        guard line.height > 0 else { return nil }
        let font = typingAttributes[.font] as? NSFont ?? Self.defaultFont
        let level = (typingAttributes[.taskLevel] as? NSNumber)?.intValue ?? 0
        return boxRect(line: line, baseline: layout.defaultBaselineOffset(for: font), font: font, level: level)
    }

    private func boxRect(line: NSRect, baseline: CGFloat, font: NSFont, level: Int) -> NSRect {
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 5
        let size = Self.boxSize
        let middle = line.minY + baseline - font.capHeight / 2
        return NSRect(x: (origin.x + line.minX + padding + Self.indent * CGFloat(level)).rounded(),
                      y: (origin.y + middle - size / 2).rounded(),
                      width: size, height: size)
    }

    /// The ▸ sits just left of where the line starts (left of its box, if it has one).
    func arrowRect(for line: LineInfo) -> NSRect? {
        guard let layout = layoutManager, line.range.location < storage.length else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: line.range.location)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = storage.attribute(.font, at: line.range.location, effectiveRange: nil) as? NSFont ?? Self.defaultFont
        let box = boxRect(line: fragment, baseline: layout.location(forGlyphAt: glyph).y, font: font, level: line.level)
        return NSRect(x: max(1, box.minX - 11), y: box.minY + 1, width: 9, height: 9)   // Stickies' margin is only 11 pt
    }

    private func drawArrow(_ rect: NSRect, folded: Bool) {
        let path = NSBezierPath()   // flipped: y grows downward
        let r = rect.insetBy(dx: 1, dy: 1)
        if folded {
            path.move(to: NSPoint(x: r.minX + 1, y: r.minY))
            path.line(to: NSPoint(x: r.maxX, y: r.midY))
            path.line(to: NSPoint(x: r.minX + 1, y: r.maxY))
        } else {
            path.move(to: NSPoint(x: r.minX, y: r.minY + 1))
            path.line(to: NSPoint(x: r.maxX, y: r.minY + 1))
            path.line(to: NSPoint(x: r.midX, y: r.maxY))
        }
        path.close()
        palette.text.withAlphaComponent(0.6).setFill()
        path.fill()
    }

    private func drawBox(_ rect: NSRect, checked: Bool, color: NSColor, faint: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        let color = faint ? color.withAlphaComponent(0.35) : color
        if checked {
            color.setFill()
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.24, y: rect.midY))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.maxY - rect.height * 0.25))
            check.line(to: NSPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY + rect.height * 0.26))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            palette.checkMark.setStroke()
            check.stroke()
        } else {
            color.setStroke()
            box.lineWidth = 1
            box.stroke()
        }
    }

    /// `fraction`: how much of the line is struck (the finish animation draws it in steps).
    private func drawStrike(paragraph: NSRange, color: NSColor, fraction: CGFloat = 1) {
        guard let layout = layoutManager, let container = textContainer, fraction > 0 else { return }
        let content = text.contentRange(of: paragraph)
        guard content.length > 0 else { return }
        let glyphs = layout.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var pieces: [(minX: CGFloat, maxX: CGFloat, y: CGFloat)] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            let bounds = layout.boundingRect(forGlyphRange: part, in: container)
            let charIndex = layout.characterIndexForGlyph(at: part.location)
            let font = self.storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont ?? Self.defaultFont
            let baseline = lineRect.minY + layout.location(forGlyphAt: part.location).y
            pieces.append((origin.x + bounds.minX, origin.x + bounds.maxX, (origin.y + baseline - font.xHeight / 2).rounded() + 0.5))
        }
        var left = pieces.reduce(0) { $0 + $1.maxX - $1.minX } * fraction
        color.setStroke()
        for piece in pieces where left > 0 {
            let width = min(piece.maxX - piece.minX, left)
            left -= width
            let line = NSBezierPath()
            line.move(to: NSPoint(x: piece.minX, y: piece.y))
            line.line(to: NSPoint(x: piece.minX + width, y: piece.y))
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// Where the line's visible text ends, and its baseline.
    private func lineEnd(of line: LineInfo) -> NSPoint? {
        guard let layout = layoutManager, let container = textContainer, line.content.length > 0 else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: NSMaxRange(line.content) - 1)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSPoint(x: origin.x + rect.maxX, y: origin.y + fragment.minY + layout.location(forGlyphAt: glyph).y)
    }

    private func drawLabels(_ labels: [(String, NSColor)], after line: LineInfo) {
        guard !labels.isEmpty, var point = lineEnd(of: line) else { return }
        let font = Self.smallFont
        point.x += 6
        for (string, color) in labels {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (string as NSString).draw(at: NSPoint(x: point.x, y: point.y - font.ascender), withAttributes: attributes)
            point.x += (string as NSString).size(withAttributes: attributes).width + 6
        }
    }

    private func drawRightLabel(_ label: String, on line: LineInfo, color: NSColor) {
        guard let end = lineEnd(of: line) else { return }
        let font = Self.smallFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (label as NSString).size(withAttributes: attributes)
        let x = bounds.width - textContainerInset.width - (textContainer?.lineFragmentPadding ?? 5) - size.width
        guard x > end.x + 4 else { return }
        (label as NSString).draw(at: NSPoint(x: x, y: end.y - font.ascender), withAttributes: attributes)
    }

    // MARK: Colors

    private var redColor: NSColor {
        palette.isDark ? NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.12, blue: 0.12, alpha: 1)
    }

    /// Normal → orange → red over the last 6 hours, red once late.
    private func urgencyColor(_ urgency: Urgency) -> NSColor? {
        let orange = NSColor(srgbRed: 0.95, green: 0.5, blue: 0.05, alpha: 1)
        switch urgency {
        case .calm: return nil
        case .overdue: return redColor
        case .warming(let p):
            let base = palette.text.usingColorSpace(.sRGB) ?? .black
            return p < 0.5
                ? base.blended(withFraction: p * 2, of: orange)
                : orange.blended(withFraction: (p - 0.5) * 2, of: redColor)
        }
    }

    /// Ticked text fades slowly over the 13 hours before it leaves the note.
    private func fadedColor(tickedAt time: Double, now: Date) -> NSColor {
        let progress = doneDelay > 0 ? min(max((now.timeIntervalSinceReferenceDate - time) / doneDelay, 0), 1) : 1
        return palette.text.withAlphaComponent(0.5 - 0.3 * progress)
    }

    /// Text color on screen, decided while drawing (so it's right in the very frame a key
    /// is typed): ticked lines fade, dates are faded, tasks warm up to red, past calendar
    /// events fade, and on dark notes black text shows light.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:],
                       forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
                       effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        guard toScreen, charIndex < storage.length else { return attrs }
        let p = paragraph(at: charIndex)
        var range = NSIntersectionRange(effectiveCharRange?.pointee ?? p, p)
        if !NSLocationInRange(charIndex, range) { range = NSRange(location: charIndex, length: 1) }
        var result = attrs
        var color: NSColor?
        let date = now()

        if let value = checklistValue(at: p) {
            if value > 0, let id = attribute(.taskID, of: p) as? String, let finish = finishing[id],
               date.timeIntervalSince(finish.start) < finish.sparkStart {
                color = nil   // still being struck through
            } else if value > 0 {
                color = fadedColor(tickedAt: value, now: date)
            } else if let taskDate = taskDate(of: p) {
                let content = text.contentRange(of: p)
                let dateRange = NSRange(location: content.location + taskDate.range.location, length: taskDate.range.length)
                let urgent = urgencyColor(Urgency(due: taskDate.due, now: date, calendar: calendar))
                if NSLocationInRange(charIndex, dateRange) {
                    range = NSIntersectionRange(range, dateRange)
                    color = (urgent ?? palette.text).withAlphaComponent(0.45)
                } else {
                    let side = charIndex < dateRange.location
                        ? NSRange(location: p.location, length: dateRange.location - p.location)
                        : NSRange(location: NSMaxRange(dateRange), length: NSMaxRange(p) - NSMaxRange(dateRange))
                    range = NSIntersectionRange(range, side)
                    color = urgent
                }
            }
        } else if role(of: p) == "event", (attribute(.boardEventEnded, of: p) as? NSNumber)?.boolValue == true {
            color = palette.text.withAlphaComponent(0.4)
        }
        if color == nil, palette.isDark {
            var run = NSRange()
            let stored = storage.attribute(.foregroundColor, at: charIndex, longestEffectiveRange: &run, in: p) as? NSColor
            range = NSIntersectionRange(range, run)
            if Self.isInk(stored) { color = palette.text }
        }
        if let color { result[.foregroundColor] = color }
        effectiveCharRange?.pointee = range
        return result
    }

    /// Black or default-colored text (as opposed to text the user colored on purpose).
    static func isInk(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return true }
        return max(c.redComponent, c.greenComponent, c.blueComponent) < 0.25
    }

    // MARK: Folding

    func computeHiddenRanges() -> [NSRange] {
        let lines = storage.lineInfos()
        var result: [NSRange] = []
        var i = 0
        while i < lines.count {
            let kids = descendants(of: i, in: lines)
            if lines[i].folded, !kids.isEmpty {
                let start = NSMaxRange(lines[i].content)
                let end = NSMaxRange(lines[kids.upperBound - 1].content)
                if end > start { result.append(NSRange(location: start, length: end - start)) }
                i = kids.upperBound
            } else {
                i += 1
            }
        }
        return result
    }

    func isHidden(_ charIndex: Int) -> Bool {
        hiddenRanges.contains { NSLocationInRange(charIndex, $0) }
    }

    private func applyHiddenRanges(_ ranges: [NSRange]) {
        guard ranges != hiddenRanges else { return }
        hiddenRanges = ranges
        guard let layout = layoutManager else { return }
        let all = NSRange(location: 0, length: storage.length)
        layout.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<glyphRange.length where isHidden(charIndexes[i]) {
            if changed == nil { changed = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
            changed![i] = .null
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer {
            layoutManager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        isHidden(charIndex) ? .zeroAdvancement : action
    }

    func toggleFold(paragraph p: NSRange) {
        let folded = !lineInfo(p).folded
        guard shouldChangeText(in: p, replacementString: nil) else { return }
        if folded {
            storage.addAttribute(.taskFolded, value: NSNumber(value: true), range: p)
        } else {
            storage.removeAttribute(.taskFolded, range: p)
        }
        didChangeText()
        undoManager?.setActionName(folded ? "Fold" : "Unfold")
        applyHiddenRanges(computeHiddenRanges())
        if let hidden = hiddenRanges.first(where: { $0.location == NSMaxRange(text.contentRange(of: p)) }),
           selectedRange().location > hidden.location, selectedRange().location <= NSMaxRange(hidden) {
            setSelectedRange(NSRange(location: hidden.location, length: 0))
        }
        refreshCheckedAppearance()
    }

    // MARK: Tooltips and cursor

    func refreshCheckedAppearance() {
        removeAllToolTips()
        for line in storage.lineInfos() where line.isTicked && !isHidden(line.range.location) {
            if let box = boxRect(forParagraphAt: line.range.location) {
                addToolTip(box.insetBy(dx: -3, dy: -2), owner: self, userData: nil)
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func queueAppearanceRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refreshCheckedAppearance()
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let p = checkboxParagraph(at: point), let value = checklistValue(at: p), value > 0 else { return "" }
        if taskDate(of: p)?.repeatRule != nil { return "Comes back fresh tomorrow" }
        let left = max(0, value + doneDelay - now().timeIntervalSinceReferenceDate)
        if left < 60 { return "Moves to the done pile in less than a minute" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = left >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return "Moves to the done pile in \(formatter.string(from: left) ?? "")"
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let lines = storage.lineInfos()
        for (index, line) in lines.enumerated() where !isHidden(line.range.location) {
            if line.isTask, let box = boxRect(forParagraphAt: line.range.location), box.intersects(visibleRect) {
                addCursorRect(box.insetBy(dx: -4, dy: -3), cursor: .pointingHand)
            }
            if !descendants(of: index, in: lines).isEmpty, let arrow = arrowRect(for: line), arrow.intersects(visibleRect) {
                addCursorRect(arrow.insetBy(dx: -2, dy: -2), cursor: .pointingHand)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // MARK: Mouse

    func checkboxParagraph(at point: NSPoint) -> NSRange? {
        let length = storage.length
        guard length > 0 else { return nil }
        let index = min(characterIndexForInsertion(at: point), length - 1)
        let p = paragraph(at: index)
        guard checklistValue(at: p) != nil, let box = boxRect(forParagraphAt: p.location) else { return nil }
        return box.insetBy(dx: -4, dy: -3).contains(point) ? p : nil
    }

    func foldArrowParagraph(at point: NSPoint) -> NSRange? {
        guard let p = lineParagraph(at: point) else { return nil }
        let lines = storage.lineInfos()
        guard let index = lines.firstIndex(where: { $0.range.location == p.location }),
              !descendants(of: index, in: lines).isEmpty,
              let arrow = arrowRect(for: lines[index]), arrow.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        return p
    }

    /// The line under the mouse (only if the point is really on that line).
    private func lineParagraph(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager, storage.length > 0 else { return nil }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        let p = paragraph(at: index)
        let glyphs = layout.glyphRange(forCharacterRange: text.contentRange(of: p).length > 0 ? text.contentRange(of: p) : p, actualCharacterRange: nil)
        var rect = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return point.y >= rect.minY && point.y <= rect.maxY ? p : nil
    }

    /// A box on a note in the background ticks with the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event {
            let point = convert(event.locationInWindow, from: nil)
            if checkboxParagraph(at: point) != nil || foldArrowParagraph(at: point) != nil { return true }
        }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isBoard, let action = boardClick(at: point) {
            action()
            return
        }
        if let p = foldArrowParagraph(at: point) {
            toggleFold(paragraph: p)
            return
        }
        if isEditable, let p = checkboxParagraph(at: point) {
            toggleCheckbox(paragraph: p)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = lineParagraph(at: point)?.location
        if hovered != hoveredLine {
            hoveredLine = hovered
            needsDisplay = true
        }
        if checkboxParagraph(at: point) != nil || foldArrowParagraph(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        if isBoard, boardClick(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    /// What a click on the board's own parts does: titles, the footer's days, a sticky's name,
    /// a folded group, a calendar day.
    private func boardClick(at point: NSPoint) -> (() -> Void)? {
        guard let p = lineParagraph(at: point), let role = role(of: p) else { return nil }
        let line = lineInfo(p)
        if role.hasPrefix("header:day:") {
            let day = String(role.dropFirst("header:day:".count))
            return { [weak self] in self?.boardDelegate?.boardDayClicked(day) }
        }
        if role.hasPrefix("header:") {
            let section = String(role.dropFirst("header:".count))
            return { [weak self] in self?.boardDelegate?.boardHeaderClicked(section) }
        }
        if role == "calendar", let day = calendarDay(at: point, line: line) {
            return { [weak self] in self?.boardDelegate?.boardDayClicked(day) }
        }
        if role == "footer", let layout = layoutManager, let container = textContainer {
            let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let index = layout.characterIndex(for: inContainer, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if index < storage.length, let section = storage.attribute(.boardSectionLink, at: index, effectiveRange: nil) as? String {
                return { [weak self] in self?.boardDelegate?.boardHeaderClicked(section) }
            }
        }
        if let group = attribute(.boardGroup, of: p) as? String {
            if role == "group" || rightLabelRect(line)?.insetBy(dx: -3, dy: -3).contains(point) == true {
                return { [weak self] in self?.boardDelegate?.boardGroupClicked(group) }
            }
        }
        return nil
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredLine != nil {
            hoveredLine = nil
            needsDisplay = true
        }
    }

    // MARK: Ticking

    /// Ticking a task ticks its subtasks; a task whose subtasks are all ticked ticks itself.
    func toggleCheckbox(paragraph p: NSRange) {
        var lines = storage.lineInfos()
        guard let index = lines.firstIndex(where: { $0.range.location == p.location }), lines[index].isTask else { return }
        let stamp = now().timeIntervalSinceReferenceDate
        let value = lines[index].isTicked ? 0 : stamp
        var changes: [Int: Double] = [index: value]
        for d in descendants(of: index, in: lines) where lines[d].isTask { changes[d] = value }
        for (k, v) in changes { lines[k].checklist = v }
        var child = index
        while let up = parent(of: child, in: lines), lines[up].isTask {
            let kids = directChildren(of: up, in: lines).filter { lines[$0].isTask }
            let allDone = !kids.isEmpty && kids.allSatisfy { lines[$0].isTicked }
            let want = allDone ? (lines[up].isTicked ? lines[up].checklist! : stamp) : 0
            if want != lines[up].checklist {
                changes[up] = want
                lines[up].checklist = want
            }
            child = up
        }
        let union = changes.keys.map { lines[$0].range }.reduce(lines[index].range) { NSUnionRange($0, $1) }
        guard shouldChangeText(in: union, replacementString: nil) else { return }
        for (k, v) in changes { storage.addAttribute(.checklist, value: NSNumber(value: v), range: lines[k].range) }
        didChangeText()
        if value > 0 {   // the clicked task, and any parent it completed
            for (k, v) in changes where v > 0 && (k == index || !descendants(of: index, in: lines).contains(k)) {
                if let id = lines[k].id ?? (isBoard ? attribute(.taskID, of: lines[k].range) as? String : nil) { startFinish(id: id) }
            }
        }
        undoManager?.setActionName(value > 0 ? "Tick" : "Untick")
        refreshCheckedAppearance()
    }

    // MARK: Editing

    @objc func toggleChecklist(_ sender: Any?) {
        let selection = selectedRange()
        let paragraphs = text.paragraphRanges(in: text.paragraphRange(for: selection))
        let allOn = paragraphs.isEmpty
            ? typingAttributes[.checklist] != nil
            : paragraphs.allSatisfy { checklistValue(at: $0) != nil }
        setChecklist(!allOn, in: selection)
        undoManager?.setActionName("Checklist")
    }

    /// Paragraph style for a line: 18 pt per level, plus 18 for the box.
    static func indentStyle(_ style: NSParagraphStyle?, level: Int, checkbox: Bool) -> NSParagraphStyle {
        let result = (style ?? .default).mutableCopy() as! NSMutableParagraphStyle
        let indent = Self.indent * CGFloat(level + (checkbox ? 1 : 0))
        result.firstLineHeadIndent = indent
        result.headIndent = indent
        return result
    }

    static func indented(_ style: NSParagraphStyle?, by delta: CGFloat) -> NSParagraphStyle {
        let result = (style ?? .default).mutableCopy() as! NSMutableParagraphStyle
        result.firstLineHeadIndent = max(0, result.firstLineHeadIndent + delta)
        result.headIndent = max(0, result.headIndent + delta)
        return result
    }

    func setChecklist(_ on: Bool, in range: NSRange) {
        let paragraphs = text.paragraphRanges(in: text.paragraphRange(for: range))
        if paragraphs.isEmpty {
            var attrs = typingAttributes
            if (attrs[.checklist] != nil) != on {
                attrs[.checklist] = on ? NSNumber(value: 0) : nil
                attrs[.paragraphStyle] = Self.indentStyle(attrs[.paragraphStyle] as? NSParagraphStyle,
                                                          level: (attrs[.taskLevel] as? NSNumber)?.intValue ?? 0, checkbox: on)
                typingAttributes = attrs
            }
            keepTrailingChecklist = on
            relayoutTrailingLine()
            return
        }
        let full = NSUnionRange(paragraphs[0], paragraphs[paragraphs.count - 1])
        guard shouldChangeText(in: full, replacementString: nil) else { return }
        storage.beginEditing()
        for p in paragraphs where (storage.attribute(.checklist, at: p.location, effectiveRange: nil) != nil) != on {
            let style = storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle
            storage.addAttribute(.paragraphStyle, value: Self.indentStyle(style, level: level(of: p), checkbox: on), range: p)
            if on {
                storage.addAttribute(.checklist, value: NSNumber(value: 0), range: p)
                if !isBoard { storage.addAttribute(.taskID, value: newTaskID(), range: p) }
            } else {
                storage.removeAttribute(.checklist, range: p)
                for key in NSAttributedString.Key.taskOnlyKeys { storage.removeAttribute(key, range: p) }
            }
        }
        storage.endEditing()
        didChangeText()
        syncTypingAttributes()
        refreshCheckedAppearance()
    }

    /// Tab / Shift-Tab: one level deeper or shallower (never more than one deeper than the line above).
    func changeLevel(by delta: Int) {
        let selection = selectedRange()
        let lines = storage.lineInfos()
        let wanted = text.paragraphRange(for: selection)
        let targets = lines.indices.filter { NSIntersectionRange(lines[$0].range, wanted).length > 0 || lines[$0].range.location == wanted.location }
        if targets.isEmpty || (wanted.length == 0 && selection.location == storage.length) {
            var attrs = typingAttributes
            let previous = lines.last?.level ?? -1
            let newLevel = max(0, min(((attrs[.taskLevel] as? NSNumber)?.intValue ?? 0) + delta, previous + 1))
            attrs[.taskLevel] = newLevel > 0 ? NSNumber(value: newLevel) : nil
            attrs[.paragraphStyle] = Self.indentStyle(attrs[.paragraphStyle] as? NSParagraphStyle, level: newLevel, checkbox: attrs[.checklist] != nil)
            typingAttributes = attrs
            keepTrailingChecklist = attrs[.checklist] != nil
            relayoutTrailingLine()
            return
        }
        let union = targets.map { lines[$0].range }.reduce(lines[targets[0]].range) { NSUnionRange($0, $1) }
        guard shouldChangeText(in: union, replacementString: nil) else { return }
        storage.beginEditing()
        var previousLevel = targets[0] > 0 ? lines[targets[0] - 1].level : -1
        for index in targets {
            let line = lines[index]
            let newLevel = max(0, min(line.level + delta, previousLevel + 1))
            previousLevel = newLevel
            if newLevel > 0 {
                storage.addAttribute(.taskLevel, value: NSNumber(value: newLevel), range: line.range)
            } else {
                storage.removeAttribute(.taskLevel, range: line.range)
            }
            let style = storage.attribute(.paragraphStyle, at: line.range.location, effectiveRange: nil) as? NSParagraphStyle
            storage.addAttribute(.paragraphStyle, value: Self.indentStyle(style, level: newLevel, checkbox: line.isTask), range: line.range)
        }
        storage.endEditing()
        didChangeText()
        revealFoldedAncestors(of: selectedRange().location)
        syncTypingAttributes()
        undoManager?.setActionName(delta > 0 ? "Indent" : "Outdent")
        refreshCheckedAppearance()
    }

    override func insertTab(_ sender: Any?) {
        if isBoard { return NSSound.beep() }
        let selection = selectedRange()
        let current = paragraph(at: selection.location)
        let multiLine = text.paragraphRanges(in: text.paragraphRange(for: selection)).count > 1
        if checklistValue(at: current) != nil || selection.location == current.location || multiLine {
            changeLevel(by: 1)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if isBoard { return NSSound.beep() }
        changeLevel(by: -1)
    }

    /// Return on a checklist line starts a new open box at the same level. Return on an
    /// empty box steps out one level, then out of the list.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let current = paragraph(at: selection.location)

        // at the end of a folded line: the new line goes below everything folded under it
        if selection.length == 0, let hidden = hiddenRanges.first(where: { $0.location == selection.location }) {
            insertLine(after: hidden, like: current)
            return
        }

        let currentLevel = level(of: current)
        let content = text.substring(with: text.contentRange(of: current)).trimmingCharacters(in: .whitespaces)
        let state = checklistValue(at: current)
        if content.isEmpty, selection.length == 0, state != nil || currentLevel > 0 {
            if currentLevel > 0 { changeLevel(by: -1) } else { setChecklist(false, in: current) }
            return
        }
        guard let state else { return super.insertNewline(sender) }

        _ = state
        // Return at the very start of a line: an empty box appears above, the line keeps its identity
        if selection.length == 0, selection.location == current.location, current.length > 0 {
            var attrs = storage.attributes(at: current.location, effectiveRange: nil)
            attrs[.checklist] = NSNumber(value: 0)
            for key in [NSAttributedString.Key.taskDue, .taskMoved, .taskFolded, .boardLabel, .boardProgress] { attrs[key] = nil }
            attrs[.taskID] = isBoard ? nil : newTaskID()
            if isBoard { attrs[.boardRole] = "new" }
            guard shouldChangeText(in: NSRange(location: current.location, length: 0), replacementString: "\n") else { return }
            storage.insert(NSAttributedString(string: "\n", attributes: attrs), at: current.location)
            didChangeText()
            setSelectedRange(NSRange(location: current.location + 1, length: 0))
            refreshCheckedAppearance()
            return
        }
        let style = attribute(.paragraphStyle, of: current)
        super.insertNewline(sender)

        let below = paragraph(at: selectedRange().location)
        if below.length > 0 { freshLine(below) }
        var attrs = typingAttributes
        attrs[.checklist] = NSNumber(value: 0)
        if let style { attrs[.paragraphStyle] = style }
        if let font = storage.attribute(.font, at: current.location, effectiveRange: nil) { attrs[.font] = font }
        for key in [NSAttributedString.Key.taskFolded, .taskDue, .taskMoved, .boardLabel, .boardProgress] { attrs[key] = nil }
        if isBoard {
            attrs[.boardRole] = "new"
            attrs[.taskID] = nil
        } else if below.length == 0 {
            attrs[.taskID] = newTaskID()   // the empty last line: a new task with its own id
        }
        typingAttributes = attrs
        keepTrailingChecklist = below.length == 0
        if below.length == 0 { relayoutTrailingLine() }
        refreshCheckedAppearance()
    }

    /// The second half of a split line: a new open task without the old one's id, date history or fold.
    private func freshLine(_ range: NSRange) {
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.checklist, value: NSNumber(value: 0), range: range)
        for key in [NSAttributedString.Key.taskDue, .taskMoved, .taskFolded, .boardLabel, .boardProgress] {
            storage.removeAttribute(key, range: range)
        }
        if isBoard {
            storage.removeAttribute(.taskID, range: range)
            storage.addAttribute(.boardRole, value: "new", range: range)
        } else {
            storage.addAttribute(.taskID, value: newTaskID(), range: range)
        }
        didChangeText()
    }

    private func insertLine(after hidden: NSRange, like line: NSRange) {
        let info = lineInfo(line)
        var attrs = storage.attributes(at: line.location, effectiveRange: nil)
        for key in [NSAttributedString.Key.taskFolded, .taskDue, .taskMoved, .taskID, .boardLabel, .boardProgress] { attrs[key] = nil }
        if info.isTask {
            attrs[.checklist] = NSNumber(value: 0)
            if !isBoard { attrs[.taskID] = newTaskID() }   // its id from the start, so typing never has to add one
        }
        if isBoard { attrs[.boardRole] = "new" }
        let end = NSMaxRange(hidden)
        let hasNewline = end < storage.length
        let insertAt = hasNewline ? end + 1 : end
        var piece = NSAttributedString(string: "\n", attributes: attrs)
        if !hasNewline { piece = NSAttributedString(string: "\n", attributes: storage.attributes(at: max(end - 1, 0), effectiveRange: nil)) }
        guard shouldChangeText(in: NSRange(location: insertAt, length: 0), replacementString: "\n") else { return }
        storage.insert(piece, at: insertAt)
        didChangeText()
        super.setSelectedRanges([NSValue(range: NSRange(location: insertAt + (hasNewline ? 0 : 1), length: 0))], affinity: .downstream, stillSelecting: false)
        typingAttributes = attrs
        keepTrailingChecklist = !hasNewline && info.isTask
        if !hasNewline { relayoutTrailingLine() }
        applyHiddenRanges(computeHiddenRanges())
        refreshCheckedAppearance()
    }

    /// Backspace at the start of a line removes its box first, then steps it out a level.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0 {
            let current = paragraph(at: selection.location)
            if selection.location == current.location {
                if isBoard, current.length > 0, role(of: current) == "task" {
                    NSSound.beep()   // a mirrored task keeps its box; edit it in its own sticky
                    return
                }
                if checklistValue(at: current) != nil {
                    setChecklist(false, in: current)
                    return
                }
                if level(of: current) > 0 {
                    changeLevel(by: -1)
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isBoard, replacementString != nil, touchesFixedBoardLine(affectedCharRange) {
            NSSound.beep()
            return false
        }
        if replacementString != nil, !isCommitting { revealFoldedAncestors(of: affectedCharRange.location) }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// If the line at `location` sits under folded lines, unfold them, so what you type never vanishes.
    private func revealFoldedAncestors(of location: Int) {
        let line = paragraph(at: min(location, storage.length))
        var level = line.length > 0 ? self.level(of: line) : ((typingAttributes[.taskLevel] as? NSNumber)?.intValue ?? 0)
        guard level > 0 else { return }
        var unfold: [NSRange] = []
        for above in storage.lineInfos().reversed() where above.range.location < line.location {
            guard above.level < level else { continue }
            if above.folded { unfold.append(above.range) }
            level = above.level
            if level == 0 { break }
        }
        guard !unfold.isEmpty else { return }
        let selection = selectedRanges
        storage.beginEditing()
        for range in unfold { storage.removeAttribute(.taskFolded, range: range) }
        storage.endEditing()
        applyHiddenRanges(computeHiddenRanges())
        super.setSelectedRanges(selection, affinity: .downstream, stillSelecting: false)
    }

    /// Safety net: after typing, the caret sits right after what was typed.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let target = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let inserted = (string as? String)?.utf16.count ?? (string as? NSAttributedString)?.length ?? 0
        let lengthBefore = storage.length
        let hadMarkedText = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        guard !hadMarkedText, !hasMarkedText(), storage.length == lengthBefore - target.length + inserted else { return }
        let expected = target.location + inserted
        if selectedRange() != NSRange(location: expected, length: 0), expected <= storage.length {
            setSelectedRange(NSRange(location: expected, length: 0))
        }
    }

    /// Section titles and calendar events on the board can't be typed into.
    private func touchesFixedBoardLine(_ range: NSRange) -> Bool {
        let probe = range.length == 0 ? NSRange(location: range.location, length: 0) : range
        let paragraphs = probe.length == 0 ? [paragraph(at: probe.location)] : text.paragraphRanges(in: text.paragraphRange(for: probe))
        return paragraphs.contains { p in
            guard p.length > 0, let role = role(of: p) else { return false }
            return ["event", "note", "counter", "calendar", "group", "footer"].contains(role) || role.hasPrefix("header:")
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        // never leave the caret inside folded-away text
        if ranges.count == 1, let r = ranges.first?.rangeValue, r.length == 0,
           let hidden = hiddenRanges.first(where: { r.location > $0.location && r.location <= NSMaxRange($0) }) {
            let forward = r.location >= selectedRange().location
            let snapped = forward ? min(NSMaxRange(hidden) + 1, storage.length) : hidden.location
            ranges = [NSValue(range: NSRange(location: snapped, length: 0))]
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, textStorage != nil {
            syncTypingAttributes()
            commitIfLeftLine()
        }
    }

    /// After every change (ours too: ticking, splitting a line), what you type next carries the
    /// line's current state. Otherwise the next letter brings stale values, the line has to be
    /// fixed up mid-keystroke, and AppKit moves the caret.
    override func didChangeText() {
        super.didChangeText()
        if !isCommitting { syncTypingAttributes() }
    }

    /// Text typed anywhere in a line, even at its very start, takes that line's state.
    private func syncTypingAttributes() {
        let current = paragraph(at: selectedRange().location)
        var attrs = typingAttributes
        if current.length > 0 {
            keepTrailingChecklist = false
            for key in NSAttributedString.Key.paragraphKeys {
                attrs[key] = storage.attribute(key, at: current.location, effectiveRange: nil)
            }
            if let style = storage.attribute(.paragraphStyle, at: current.location, effectiveRange: nil) {
                attrs[.paragraphStyle] = style
            }
            // right after a (small) date, keep typing in the line's own size
            if checklistValue(at: current) != nil, let date = taskDate(of: current),
               selectedRange().location > text.contentRange(of: current).location + date.range.location,
               let font = storage.attribute(.font, at: current.location, effectiveRange: nil) {
                attrs[.font] = font
            }
        } else {
            // the empty last line is a new line: nothing of the line above but its look
            var leftovers = [NSAttributedString.Key.taskFolded, .taskDue, .taskMoved, .boardLabel, .boardProgress]
            if !keepTrailingChecklist { leftovers.append(.taskID) }
            let hadLeftovers = leftovers.contains { attrs[$0] != nil }
            leftovers.forEach { attrs[$0] = nil }
            if !keepTrailingChecklist, attrs[.checklist] != nil {
                attrs[.checklist] = nil
                attrs[.paragraphStyle] = Self.indentStyle(attrs[.paragraphStyle] as? NSParagraphStyle,
                                                          level: (attrs[.taskLevel] as? NSNumber)?.intValue ?? 0, checkbox: false)
            } else if !hadLeftovers {
                return
            }
        }
        typingAttributes = attrs
        if current.length == 0 { relayoutTrailingLine() }
        needsDisplay = true
    }

    /// The empty last line is laid out from the typing attributes, so redo it when they change.
    private func relayoutTrailingLine() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.textContainerChangedGeometry(container)
        needsDisplay = true
    }

    @objc func toggleStrikethrough(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 {
            var attrs = typingAttributes
            attrs[.strikethroughStyle] = (attrs[.strikethroughStyle] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : nil
            typingAttributes = attrs
            return
        }
        let struck = (storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if struck {
            storage.removeAttribute(.strikethroughStyle, range: range)
        } else {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        didChangeText()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleChecklist(_:)) {
            item.state = checklistValue(at: paragraph(at: selectedRange().location)) != nil ? .on : .off
            return isEditable && !isBoard
        }
        if item.action == #selector(toggleStrikethrough(_:)) {
            let range = selectedRange()
            let value = range.length > 0 && range.location < storage.length
                ? storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil)
                : typingAttributes[.strikethroughStyle]
            item.state = (value as? Int ?? 0) != 0 ? .on : .off
            return isEditable
        }
        return super.validateMenuItem(item)
    }

    // MARK: Committing dates

    /// When the caret leaves a line: fix its date ("fri" → "Fri 16 Oct"), count late moves,
    /// and on the board file a newly typed task away.
    ///
    /// The work is queued until the current keystroke is finished: changing text in the middle of
    /// one of AppKit's edits moves the caret.
    private func commitIfLeftLine() {
        guard !isCommitting else { return }
        let current = paragraph(at: selectedRange().location)
        let currentID = current.length > 0 ? storage.attribute(.taskID, at: current.location, effectiveRange: nil) as? String : nil
        defer {
            lastLineLocation = current.location
            lastLineID = currentID
        }
        guard let previous = lastLineLocation, previous != current.location else { return }
        if let id = lastLineID, id != currentID { pendingCommitIDs.append(id) }
        if isBoard { pendingBoardFiling = true }
        guard !commitScheduled else { return }
        commitScheduled = true
        Self.waiting.add(self)
        DispatchQueue.main.async { [weak self] in self?.commitPendingNow() }
    }

    /// Runs the queued commits now (they normally run right after the keystroke).
    func commitPendingNow() {
        Self.waiting.remove(self)
        commitScheduled = false
        let ids = pendingCommitIDs
        let fileBoardLines = pendingBoardFiling
        pendingCommitIDs = []
        pendingBoardFiling = false
        let caretLine = paragraph(at: selectedRange().location)
        isCommitting = true
        for id in ids {
            guard let p = taskRange(id: id), p.location != caretLine.location else { continue }   // not the line you're on
            commitTask(at: p)
        }
        isCommitting = false
        if !ids.isEmpty { sortTasksByDate() }
        if fileBoardLines { boardDelegate?.boardFileTypedLines(except: paragraph(at: selectedRange().location)) }
        boardDelegate?.boardCaretChangedLine()
    }

    /// The board line the caret is on was typed by the user and not filed yet.
    var hasUnfiledBoardLine: Bool {
        text.allParagraphs.contains { p in
            guard let role = role(of: p), role == "new" || role == "slot" else { return false }
            return !text.substring(with: text.contentRange(of: p)).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private static let waiting = NSHashTable<ChecklistTextView>.weakObjects()

    /// Runs every text view's queued commits right away (quitting, and tests).
    static func commitAllPending() {
        for view in waiting.allObjects { view.commitPendingNow() }
    }

    /// Commits every task line (used when the note loses focus or the app quits).
    func commitAll() {
        pendingCommitIDs = []
        isCommitting = true
        defer { isCommitting = false }
        for p in text.allParagraphs.reversed() where checklistValue(at: p) != nil {
            commitTask(at: p)
        }
        isCommitting = false
        sortTasksByDate()
    }

    @discardableResult
    func commitTask(at p: NSRange) -> Bool {
        guard p.length > 0, let value = checklistValue(at: p) else { return false }
        let date = now()
        let content = text.contentRange(of: p)
        let contentString = text.substring(with: content)
        let parsed = DateParser.parse(contentString, now: date, calendar: calendar)
        var changed = false

        if let parsed, parsed.repeatRule == nil {
            let dateRange = NSRange(location: content.location + parsed.range.location, length: parsed.range.length)
            let baseFont = storage.attribute(.font, at: dateRange.location, effectiveRange: nil) as? NSFont ?? Self.defaultFont
            let small = NSFontManager.shared.convert(baseFont, toSize: 10)
            if parsed.needsRewrite(of: contentString, now: date, calendar: calendar) {
                let display = parsed.due.display(now: date, calendar: calendar)
                var attrs = storage.attributes(at: dateRange.location, effectiveRange: nil)
                attrs[.font] = small
                replaceKeepingSelection(dateRange, with: NSAttributedString(string: display, attributes: attrs))
                changed = true
            } else if baseFont.pointSize > 10, shouldChangeText(in: dateRange, replacementString: nil) {
                storage.addAttribute(.font, value: small, range: dateRange)
                didChangeText()
                changed = true
            }
        }

        // count moves of a late task, remember the date it's now on
        let line = paragraph(at: p.location)
        let oldKey = storage.attribute(.taskDue, at: line.location, effectiveRange: nil) as? String
        let newKey = (parsed?.repeatRule == nil && value == 0) ? parsed?.due.key : oldKey
        if oldKey != newKey, shouldChangeText(in: line, replacementString: nil) {
            if let oldKey, newKey != nil, let old = DueDate(key: oldKey), Urgency(due: old, now: date, calendar: calendar) == .overdue {
                let moved = (storage.attribute(.taskMoved, at: line.location, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
                storage.addAttribute(.taskMoved, value: NSNumber(value: moved + 1), range: line)
            }
            if let newKey { storage.addAttribute(.taskDue, value: newKey, range: line) } else { storage.removeAttribute(.taskDue, range: line) }
            didChangeText()
            changed = true
        }
        return changed
    }

    private func replaceKeepingSelection(_ range: NSRange, with replacement: NSAttributedString) {
        var selection = selectedRange()
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        let delta = replacement.length - range.length
        if selection.location >= NSMaxRange(range) { selection.location += delta }
        selection.location = min(selection.location, storage.length)
        selection.length = min(selection.length, storage.length - selection.location)
        super.setSelectedRanges([NSValue(range: selection)], affinity: .downstream, stillSelecting: false)
    }

    // MARK: Sorting by date

    /// Within each block of sibling tasks (plain-text lines are the block edges), dated tasks go
    /// first, earliest on top, and undated ones follow in your order. Subtasks move with their parent.
    @discardableResult
    func sortTasksByDate(undoable: Bool = true) -> Bool {
        guard !isBoard else { return false }
        let lines = storage.lineInfos()
        guard lines.count > 1 else { return false }
        func key(_ i: Int) -> (Int, Int, Int, Int)? {   // nil = no date
            guard lines[i].isTask, let d = taskDate(of: lines[i].range) else { return nil }
            return (d.due.year, d.due.month, d.due.day, d.due.minute ?? Int.max)
        }
        func order(_ range: Range<Int>) -> [Int] {
            var items: [[Int]] = []   // a line and everything nested under it
            var i = range.lowerBound
            while i < range.upperBound {
                let end = min(descendants(of: i, in: lines).upperBound, range.upperBound)
                items.append([i] + order((i + 1)..<end))
                i = end
            }
            var result: [Int] = []
            var run: [[Int]] = []
            func flushRun() {
                let sorted = run.enumerated().sorted { a, b in
                    switch (key(a.element[0]), key(b.element[0])) {
                    case let (x?, y?): return x != y ? x < y : a.offset < b.offset
                    case (.some, nil): return true
                    case (nil, .some): return false
                    default: return a.offset < b.offset
                    }
                }
                result += sorted.flatMap(\.element)
                run = []
            }
            for item in items {
                if lines[item[0]].isTask { run.append(item) } else { flushRun(); result += item }
            }
            flushRun()
            return result
        }
        let newOrder = order(0..<lines.count)
        guard newOrder != Array(0..<lines.count) else { return false }

        let endsWithNewline = isNewline(text.character(at: text.length - 1))
        let rebuilt = NSMutableAttributedString()
        var newStart: [Int: Int] = [:]
        for k in newOrder {
            newStart[k] = rebuilt.length
            let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: lines[k].range))
            if lines[k].content.length == lines[k].range.length {   // the old last line needs a newline now
                let attrs = piece.length > 0 ? piece.attributes(at: piece.length - 1, effectiveRange: nil) : [:]
                piece.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            rebuilt.append(piece)
        }
        if !endsWithNewline { rebuilt.deleteCharacters(in: NSRange(location: rebuilt.length - 1, length: 1)) }

        // the caret stays on its line
        let caret = selectedRange().location
        var newCaret = rebuilt.length
        if let k = lines.firstIndex(where: { NSLocationInRange(caret, $0.range) || (caret == NSMaxRange($0.range) && $0.content.length == $0.range.length) }) {
            newCaret = min(newStart[k]! + caret - lines[k].range.location, rebuilt.length)
        }

        let wasCommitting = isCommitting
        isCommitting = true
        defer { isCommitting = wasCommitting }
        let whole = NSRange(location: 0, length: storage.length)
        if undoable, !shouldChangeText(in: whole, replacementString: rebuilt.string) { return false }
        storage.replaceCharacters(in: whole, with: rebuilt)
        if undoable {
            didChangeText()
            undoManager?.setActionName("Sort by Date")
        }
        super.setSelectedRanges([NSValue(range: NSRange(location: newCaret, length: 0))], affinity: .downstream, stillSelecting: false)
        let line = paragraph(at: newCaret)
        lastLineLocation = line.location
        lastLineID = line.length > 0 ? storage.attribute(.taskID, at: line.location, effectiveRange: nil) as? String : nil
        applyHiddenRanges(computeHiddenRanges())
        syncTypingAttributes()
        refreshCheckedAppearance()
        return true
    }

    /// Earlier versions let the small date size leak into the next lines. Puts 10 pt Helvetica
    /// outside dates back to the default size. Returns whether anything changed.
    @discardableResult
    func repairLeakedDateFont(defaultSize: CGFloat) -> Bool {
        let small = Self.smallFont
        var fixes: [NSRange] = []
        for p in text.allParagraphs {
            let content = text.contentRange(of: p)
            var date = NSRange(location: NSNotFound, length: 0)
            if checklistValue(at: p) != nil, let parsed = taskDate(of: p) {
                date = NSRange(location: content.location + parsed.range.location, length: parsed.range.length)
            }
            storage.enumerateAttribute(.font, in: p) { value, range, _ in
                guard let font = value as? NSFont, font.fontName == small.fontName, font.pointSize == small.pointSize else { return }
                let outside = date.location == NSNotFound ? range : NSRange(location: range.location, length: max(0, min(NSMaxRange(range), date.location) - range.location))
                if outside.length > 0 { fixes.append(outside) }
                if date.location != NSNotFound, NSMaxRange(range) > NSMaxRange(date) {
                    let after = NSRange(location: max(range.location, NSMaxRange(date)), length: NSMaxRange(range) - max(range.location, NSMaxRange(date)))
                    if after.length > 0 { fixes.append(after) }
                }
            }
        }
        guard !fixes.isEmpty else { return false }
        let normal = NSFontManager.shared.convert(small, toSize: defaultSize)
        storage.beginEditing()
        for range in fixes { storage.addAttribute(.font, value: normal, range: range) }
        storage.endEditing()
        return true
    }

    // MARK: Changes coming from the day board

    func replaceTaskContent(id: String, with content: NSAttributedString) {
        guard let p = taskRange(id: id) else { return }
        let old = text.contentRange(of: p)
        guard text.substring(with: old) != content.string || content.length == 0 && old.length > 0 else { return }
        var kept: [NSAttributedString.Key: Any] = [:]
        for key in NSAttributedString.Key.paragraphKeys + [.paragraphStyle] {
            kept[key] = storage.attribute(key, at: p.location, effectiveRange: nil)
        }
        guard shouldChangeText(in: old, replacementString: content.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: old, with: content)
        let line = NSRange(location: p.location, length: p.length - old.length + content.length)
        if line.length > 0 {
            for key in NSAttributedString.Key.paragraphKeys { storage.removeAttribute(key, range: line) }
            storage.addAttributes(kept, range: line)
        }
        storage.endEditing()
        didChangeText()
    }

    func setTaskTicked(id: String, _ ticked: Bool) {
        guard let p = taskRange(id: id), let value = checklistValue(at: p), (value > 0) != ticked else { return }
        toggleCheckbox(paragraph: p)
    }

    func setTaskFolded(id: String, _ folded: Bool) {
        guard let p = taskRange(id: id), lineInfo(p).folded != folded else { return }
        toggleFold(paragraph: p)
    }

    func setTaskDueAnchor(id: String, due: String?, moved: Int) {
        guard let p = taskRange(id: id), shouldChangeText(in: p, replacementString: nil) else { return }
        if let due { storage.addAttribute(.taskDue, value: due, range: p) } else { storage.removeAttribute(.taskDue, range: p) }
        if moved > 0 { storage.addAttribute(.taskMoved, value: NSNumber(value: moved), range: p) } else { storage.removeAttribute(.taskMoved, range: p) }
        didChangeText()
    }

    func deleteTask(id: String) {
        guard var p = taskRange(id: id) else { return }
        if NSMaxRange(p) == storage.length, !isNewline(text.character(at: storage.length - 1)), p.location > 0 {
            p = NSRange(location: p.location - 1, length: p.length + 1)   // last line: take the newline before it
        }
        guard shouldChangeText(in: p, replacementString: "") else { return }
        storage.deleteCharacters(in: p)
        didChangeText()
    }

    // MARK: Keeping lines consistent

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        normalizeParagraphs(textStorage, editedRange: editedRange, boardMode: isBoard)
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        // decided before the layout manager lays out the edit, so folded text stays hidden
        let hidden = computeHiddenRanges()
        if hidden != hiddenRanges {
            hiddenRanges = hidden
            queueFullRelayout()
        }
        queueAppearanceRefresh()
    }

    private func queueFullRelayout() {
        guard !relayoutQueued else { return }
        relayoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let layout = self.layoutManager else { return }
            self.relayoutQueued = false
            let all = NSRange(location: 0, length: self.storage.length)
            layout.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            self.needsDisplay = true
        }
    }

    // MARK: The 13-hour sweep

    /// Removes lines ticked more than `doneDelay` ago and returns them for the done pile.
    /// Repeating tasks stay: they're reset to open once the day they were ticked on ends.
    func removeExpiredItems(now: Double) -> [DoneItem] {
        let endedWithNewline = text.length > 0 && isNewline(text.character(at: text.length - 1))
        let nowDate = Date(timeIntervalSinceReferenceDate: now)
        var expired: [(NSRange, Double)] = []
        var reset: [(NSRange, Double)] = []
        for p in text.allParagraphs {
            guard let value = checklistValue(at: p), value > 0 else { continue }
            if taskDate(of: p)?.repeatRule != nil {
                let tickedDay = TaskClock.logicalToday(now: Date(timeIntervalSinceReferenceDate: value), calendar: calendar)
                if DueDate(day: tickedDay, calendar: calendar).deadline(calendar) <= nowDate { reset.append((p, value)) }
            } else if now - value >= doneDelay {
                expired.append((p, value))
            }
        }
        guard !expired.isEmpty || !reset.isEmpty else { return [] }

        var items: [DoneItem] = []
        storage.beginEditing()
        for (p, value) in reset {
            items.append(DoneItem(text: doneText(of: p), finishedAt: Date(timeIntervalSinceReferenceDate: value)))
            storage.addAttribute(.checklist, value: NSNumber(value: 0), range: p)
        }
        for (p, value) in expired.reversed() {
            let line = doneText(of: p)
            if !line.isEmpty { items.append(DoneItem(text: line, finishedAt: Date(timeIntervalSinceReferenceDate: value))) }
            storage.deleteCharacters(in: p)
        }
        let after = storage.string as NSString
        if !endedWithNewline, after.length > 0, isNewline(after.character(at: after.length - 1)) {
            storage.deleteCharacters(in: NSRange(location: after.length - 1, length: 1))
        }
        storage.endEditing()
        undoManager?.removeAllActions()
        applyHiddenRanges(computeHiddenRanges())
        syncTypingAttributes()
        refreshCheckedAppearance()
        return items
    }

    /// A line as it goes into the done pile: no attachment marks, no date words.
    private func doneText(of p: NSRange) -> String {
        var line = text.substring(with: text.contentRange(of: p))
        if let date = taskDate(of: p) {
            line = (line as NSString).replacingCharacters(in: date.range, with: "")
        }
        return line.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Adds an open checklist line at the end (a task put back from the done pile,
    /// or filed here from the day board). Returns its task id.
    @discardableResult
    func appendChecklistLine(_ line: NSAttributedString, level: Int = 0) -> String {
        let id = newTaskID()
        let s = storage.string as NSString
        storage.beginEditing()
        if s.length > 0, !isNewline(s.character(at: s.length - 1)) {
            storage.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: s.length - 1, effectiveRange: nil)))
        }
        let start = storage.length
        storage.append(line)
        let range = NSRange(location: start, length: line.length)
        let style = Self.indentStyle(nil, level: level, checkbox: true)
        storage.addAttributes([.paragraphStyle: style, .checklist: NSNumber(value: 0), .taskID: id], range: range)
        for key in [NSAttributedString.Key.taskDue, .taskMoved, .taskFolded, .boardRole, .boardLabel, .boardProgress, .boardEventEnded] {
            storage.removeAttribute(key, range: range)
        }
        if level > 0 { storage.addAttribute(.taskLevel, value: NSNumber(value: level), range: range) } else { storage.removeAttribute(.taskLevel, range: range) }
        storage.endEditing()
        undoManager?.removeAllActions()
        if let p = taskRange(id: id) {
            isCommitting = true
            commitTask(at: p)
            isCommitting = false
        }
        refreshCheckedAppearance()
        return id
    }

    func appendChecklistLine(_ text: String, font: NSFont) {
        appendChecklistLine(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
    }
}
