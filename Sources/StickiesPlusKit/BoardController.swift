import AppKit

/// Where the day board gets calendar events from (EventKit in the app, a stub in tests).
protocol BoardEventSource: AnyObject {
    func events(on day: Date) -> [BoardEvent]
    var onChange: (() -> Void)? { get set }
}

/// Runs the day board: rebuilds it from all stickies, sends edits and ticks made on the
/// board back to the sticky each task lives in, and files new lines typed on it.
final class BoardController: NSObject, BoardTextDelegate {
    let sticky: StickyController
    var notes: () -> [StickyController] = { [] }
    /// Makes a new sticky with this first line (for a missing random pile).
    var createNote: (String) -> StickyController? = { _ in nil }
    var events: BoardEventSource? {
        didSet { events?.onChange = { [weak self] in self?.requestRebuild() } }
    }
    /// Open tasks today and how many of them are late (for the menu bar).
    var onCounts: ((Int, Int) -> Void)?
    var now: () -> Date = { Date() }
    var calendar = Calendar.current

    private(set) var mirrors: [String: BoardMirror] = [:]
    /// The day clicked in the calendar, listed under it (until clicked again).
    private(set) var selectedDay: Date?
    private var needsRebuild = false
    private var isRebuilding = false
    private var lastEdit = Date.distantPast
    private var rebuildWork: DispatchWorkItem?

    var textView: ChecklistTextView { sticky.textView }

    init(sticky: StickyController) {
        self.sticky = sticky
        super.init()
        sticky.board = self
        textView.boardDelegate = self
    }

    // MARK: Rebuilding

    /// While you're typing on the board it waits until you leave the line.
    private var isBeingEdited: Bool {
        sticky.window.isKeyWindow && sticky.window.firstResponder === textView
            && (Date().timeIntervalSince(lastEdit) < 4 || textView.hasUnfiledBoardLine)
    }

    func requestRebuild() {
        if isBeingEdited {
            needsRebuild = true
            return
        }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func rebuild() {
        guard !isRebuilding else { return }
        rebuildWork?.cancel()
        isRebuilding = true
        defer { isRebuilding = false }
        let caret = captureCaret()
        let date = now()
        let today = TaskClock.logicalToday(now: date, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let source = notes().filter { !$0.meta.isBoard }.map {
            BoardNote(id: $0.meta.id, title: $0.title, text: $0.textView.textStorage!, color: $0.meta.color,
                      doneToday: $0.meta.done.map(\.finishedAt))
        }
        let result = BoardBuilder.build(notes: source, today: events?.events(on: today) ?? [],
                                        tomorrow: events?.events(on: tomorrow) ?? [],
                                        open: Set(sticky.meta.boardOpen), foldedGroups: Set(sticky.meta.boardFoldedGroups),
                                        calendarOn: sticky.meta.boardCalendar, selectedDay: selectedDay,
                                        now: date, calendar: calendar)
        textView.textStorage?.setAttributedString(result.text)
        mirrors = result.mirrors
        needsRebuild = false
        restoreCaret(caret)
        textView.undoManager?.removeAllActions()
        textView.refreshCheckedAppearance()
        sticky.updateTitle()
        onCounts?(result.openToday, result.overdue)
    }

    private struct Caret {
        var taskID: String?
        var offset: Int
        var section: String?
        var location: Int
    }

    private func captureCaret() -> Caret? {
        guard sticky.window.firstResponder === textView, let storage = textView.textStorage else { return nil }
        let location = textView.selectedRange().location
        let p = textView.paragraph(at: location)
        let id = p.length > 0 ? storage.attribute(.taskID, at: p.location, effectiveRange: nil) as? String : nil
        return Caret(taskID: id, offset: location - p.location, section: section(of: p)?.rawValue, location: location)
    }

    private func restoreCaret(_ caret: Caret?) {
        guard let caret, let storage = textView.textStorage else { return }
        let s = storage.string as NSString
        var target = min(caret.location, storage.length)
        if let id = caret.taskID, let p = textView.taskRange(id: id) {
            target = p.location + min(caret.offset, s.contentRange(of: p).length)
        } else if let section = caret.section, let slot = s.allParagraphs.first(where: {
            storage.attribute(.boardRole, at: $0.location, effectiveRange: nil) as? String == "slot"
                && self.section(of: $0)?.rawValue == section
        }) {
            target = slot.location
        }
        textView.setSelectedRange(NSRange(location: target, length: 0))
    }

    /// The section a board line is in (the header above it).
    func section(of paragraph: NSRange) -> BoardSection? {
        header(above: paragraph).flatMap { BoardSection(rawValue: $0) }
    }

    /// The calendar day a board line is listed under, if it's under a picked day.
    func pickedDay(of paragraph: NSRange) -> Date? {
        guard let header = header(above: paragraph), header.hasPrefix("day:") else { return nil }
        return DueDate(key: String(header.dropFirst(4)))?.startOfDay(calendar)
    }

    private func header(above paragraph: NSRange) -> String? {
        guard let storage = textView.textStorage else { return nil }
        let s = storage.string as NSString
        var location = min(paragraph.location, max(storage.length - 1, 0))
        while storage.length > 0 {
            let p = s.paragraphRange(for: NSRange(location: location, length: 0))
            if let role = storage.attribute(.boardRole, at: p.location, effectiveRange: nil) as? String, role.hasPrefix("header:") {
                return String(role.dropFirst("header:".count))
            }
            if p.location == 0 { break }
            location = p.location - 1
        }
        return nil
    }

    // MARK: Board → stickies

    /// Called for every change in the board's text that the user made.
    func boardTextDidChange() {
        guard !isRebuilding, let storage = textView.textStorage else { return }
        lastEdit = Date()
        let s = storage.string as NSString
        var present = Set<String>()
        var knockOn = false
        for line in storage.lineInfos() {
            guard storage.attribute(.boardRole, at: line.range.location, effectiveRange: nil) as? String == "task",
                  let id = line.id, var mirror = mirrors[id] else { continue }
            present.insert(id)
            guard let note = note(mirror.noteID) else { continue }
            let content = s.substring(with: line.content)
            if content != mirror.content {
                note.textView.replaceTaskContent(id: id, with: Self.plain(storage.attributedSubstring(from: line.content)))
                mirror.content = content
            }
            if line.isTicked != (mirror.checklist > 0) {
                note.textView.setTaskTicked(id: id, line.isTicked)
                mirror.checklist = line.checklist ?? 0
                knockOn = true
            }
            if line.folded != mirror.folded {
                note.textView.setTaskFolded(id: id, line.folded)
                mirror.folded = line.folded
            }
            let due = storage.attribute(.taskDue, at: line.range.location, effectiveRange: nil) as? String
            if due != mirror.due || line.moved != mirror.moved {
                note.textView.setTaskDueAnchor(id: id, due: due, moved: line.moved)
                note.textView.sortTasksByDate()
                mirror.due = due
                mirror.moved = line.moved
                knockOn = true
            }
            mirrors[id] = mirror
        }
        for (id, mirror) in mirrors where !present.contains(id) {
            note(mirror.noteID)?.textView.deleteTask(id: id)
            mirrors[id] = nil
            knockOn = true
        }
        // a tick can tick a parent or subtasks, a new date can move a task to another section
        if knockOn { DispatchQueue.main.async { [weak self] in self?.rebuild() } }
    }

    func boardCaretChangedLine() {
        if needsRebuild { DispatchQueue.main.async { [weak self] in self?.rebuild() } }
    }

    func didResignKey() {
        let filed = fileUnfiledLines()
        if needsRebuild || filed { rebuild() }
    }

    /// Files every line typed on the board that wasn't filed yet (the board loses focus, the app quits).
    @discardableResult
    func fileUnfiledLines(except skipped: NSRange? = nil) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let s = storage.string as NSString
        let unfiled = s.allParagraphs.filter { p in
            guard p.location != skipped?.location,
                  let role = storage.attribute(.boardRole, at: p.location, effectiveRange: nil) as? String,
                  role == "new" || role == "slot" else { return false }
            return !s.substring(with: s.contentRange(of: p)).trimmingCharacters(in: .whitespaces).isEmpty
        }
        unfiled.forEach(fileLine)
        return !unfiled.isEmpty
    }

    private func note(_ id: UUID) -> StickyController? { notes().first { $0.meta.id == id } }

    /// Text for a sticky: no board-only line attributes, no paragraph style.
    static func plain(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: copy.length)
        for key in NSAttributedString.Key.paragraphKeys + [.paragraphStyle] { copy.removeAttribute(key, range: all) }
        return copy
    }

    // MARK: New lines typed on the board

    /// The caret left a line typed on the board: file it (and any other typed line), then refresh.
    func boardFileTypedLines(except caretLine: NSRange) {
        guard fileUnfiledLines(except: caretLine) else { return }
        lastEdit = .distantPast
        rebuild()
    }

    private func fileLine(at paragraph: NSRange) {
        guard let storage = textView.textStorage else { return }
        let s = storage.string as NSString
        let section = self.section(of: paragraph) ?? .today
        let day = pickedDay(of: paragraph)
        let line = NSMutableAttributedString(attributedString: Self.plain(storage.attributedSubstring(from: s.contentRange(of: paragraph))))

        // "#music" files it in that sticky
        var target: StickyController?
        if let match = line.string.range(of: #"(^|\s)#[^\s#]+"#, options: [.regularExpression, .backwards]) {
            let ns = NSRange(match, in: line.string)
            let tag = line.string[match].trimmingCharacters(in: .whitespaces).dropFirst()
            target = sticky(named: String(tag))
            if target != nil { line.deleteCharacters(in: ns) }
        }
        if target == nil { target = randomPile() }
        guard let target else { return }

        // no date written: the section's day
        let trimmed = line.string.trimmingCharacters(in: .whitespaces)
        if DateParser.parse(trimmed, now: now(), calendar: calendar) == nil {
            var words: String
            switch section {
            case .today: words = "today"
            case .tomorrow: words = "tomorrow"
            case .week:
                let sunday = BoardBuilder.endOfWeek(TaskClock.logicalToday(now: now(), calendar: calendar), calendar: calendar)
                words = DueDate(day: sunday, calendar: calendar).display(now: now(), calendar: calendar)
            case .later: words = "next week"
            }
            if let day { words = DueDate(day: day, calendar: calendar).display(now: now(), calendar: calendar) }
            let attrs = line.length > 0 ? line.attributes(at: line.length - 1, effectiveRange: nil) : [:]
            line.append(NSAttributedString(string: (line.string.hasSuffix(" ") ? "" : " ") + words, attributes: attrs))
        }
        while let first = line.string.first, first == " " { line.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        if line.attribute(.font, at: 0, effectiveRange: nil) == nil {
            line.addAttribute(.font, value: ChecklistTextView.defaultFont, range: NSRange(location: 0, length: line.length))
        }

        target.textView.appendChecklistLine(line)
        target.textView.sortTasksByDate()
        target.updateTitle()
        target.scheduleSave()
        // mark it filed so it can't be filed twice before the board is rebuilt
        storage.addAttribute(.boardRole, value: "filed", range: paragraph)
    }

    /// A sticky whose first line matches the tag: exact first, then starting with it.
    func sticky(named tag: String) -> StickyController? {
        let wanted = Self.fold(tag)
        let candidates = notes().filter { !$0.meta.isBoard }
        return candidates.first { Self.fold($0.title) == wanted }
            ?? candidates.first { Self.fold($0.title).hasPrefix(wanted) }
            ?? candidates.first { $0.title.split(separator: " ").contains { Self.fold(String($0)) == wanted } }
    }

    /// The sticky called "random pile" (or "random"); made if it doesn't exist yet.
    func randomPile() -> StickyController? {
        let candidates = notes().filter { !$0.meta.isBoard }
        return candidates.first { Self.fold($0.title).hasPrefix("randompile") }
            ?? candidates.first { Self.fold($0.title).hasPrefix("random") }
            ?? createNote("random pile")
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .whitespaces).joined()
    }

    // MARK: Sections

    /// The date title shows or hides the calendar; the other days' titles open and fold their section.
    func boardHeaderClicked(_ section: String) {
        if section == BoardSection.today.rawValue {
            sticky.updateBoardSettings { $0.boardCalendar.toggle() }
            if !sticky.meta.boardCalendar { selectedDay = nil }
            sticky.spine.needsDisplay = true   // the calendar button shows whether it's open
            rebuild()
            return
        }
        var open = sticky.meta.boardOpen
        if let index = open.firstIndex(of: section) { open.remove(at: index) } else { open.append(section) }
        sticky.setBoardOpen(open)
        rebuild()
    }

    func toggleCalendar() { boardHeaderClicked(BoardSection.today.rawValue) }

    func boardGroupClicked(_ group: String) {
        sticky.updateBoardSettings { meta in
            if let i = meta.boardFoldedGroups.firstIndex(of: group) { meta.boardFoldedGroups.remove(at: i) } else { meta.boardFoldedGroups.append(group) }
        }
        rebuild()
    }

    func boardDayClicked(_ day: String) {
        let date = DueDate(key: day)?.startOfDay(calendar)
        selectedDay = selectedDay == date ? nil : date
        rebuild()
    }
}
