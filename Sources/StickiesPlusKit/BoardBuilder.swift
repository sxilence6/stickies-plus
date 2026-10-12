import AppKit

/// A calendar event for the board.
struct BoardEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
}

enum BoardSection: String, CaseIterable {
    case today, tomorrow, week, later

    var title: String {
        switch self {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .week: return "This week"
        case .later: return "Later"
        }
    }
}

/// A sticky, as the board reads it.
struct BoardNote {
    var id: UUID
    var title: String
    var text: NSAttributedString
    var color: StickyColor = .yellow
    var doneToday: [Date] = []   // finish times of done-pile items (ticked tasks already swept away)
}

/// What the board last showed for a mirrored task, to notice what the user changed.
struct BoardMirror: Equatable {
    var noteID: UUID
    var content: String
    var checklist: Double
    var folded: Bool
    var due: String?
    var moved: Int
}

/// One dated task and the undated subtasks that travel with it.
struct BoardEntry {
    struct Line {
        var info: LineInfo
        var content: NSAttributedString
        var relativeLevel: Int
        var due: String?
    }

    var noteID: UUID
    var noteIndex: Int
    var label: String
    var task: Line
    var date: TaskDate
    var progress: String?
    var children: [Line]
}

/// Builds the day board's text from all stickies. Today: the date, the punch card, late tasks,
/// calendar events, then each sticky's tasks as a group. Tomorrow, This week and Later sit in
/// one line at the bottom until you open them.
enum BoardBuilder {
    struct Result {
        var text: NSAttributedString
        var mirrors: [String: BoardMirror]
        var openToday: Int
        var overdue: Int
    }

    static var headerFont: NSFont { NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12) }
    static var countFont: NSFont { NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11) }
    static let quiet = NSColor(white: 0.5, alpha: 1)

    // MARK: Collecting

    static func entries(notes: [BoardNote], now: Date, calendar: Calendar) -> [BoardEntry] {
        var result: [BoardEntry] = []
        for (noteIndex, note) in notes.enumerated() {
            let s = note.text.string as NSString
            let lines = note.text.lineInfos()
            func content(_ line: LineInfo) -> NSAttributedString { note.text.attributedSubstring(from: line.content) }
            func date(_ line: LineInfo) -> TaskDate? { DateParser.parse(s.substring(with: line.content), now: now, calendar: calendar) }
            func due(_ line: LineInfo) -> String? { note.text.attribute(.taskDue, at: line.range.location, effectiveRange: nil) as? String }

            for (index, line) in lines.enumerated() where line.isTask && line.id != nil {
                guard let taskDate = date(line) else { continue }
                var children: [BoardEntry.Line] = []
                let nested = descendants(of: index, in: lines)
                var j = nested.lowerBound
                while j < nested.upperBound {
                    let child = lines[j]
                    if child.isTask, date(child) != nil {   // a subtask with its own date shows up on its own
                        j = descendants(of: j, in: lines).upperBound
                        continue
                    }
                    children.append(.init(info: child, content: content(child), relativeLevel: child.level - line.level, due: due(child)))
                    j += 1
                }
                let kids = directChildren(of: index, in: lines).filter { lines[$0].isTask }
                let progress = kids.isEmpty ? nil : "\(kids.filter { lines[$0].isTicked }.count)/\(kids.count)"
                var label = note.title
                if let up = parent(of: index, in: lines), lines[up].isTask {
                    label = shortTitle(s.substring(with: lines[up].content), now: now, calendar: calendar)
                }
                result.append(BoardEntry(noteID: note.id, noteIndex: noteIndex, label: label,
                                         task: .init(info: line, content: content(line), relativeLevel: 0, due: due(line)),
                                         date: taskDate, progress: progress, children: children))
            }
        }
        return result
    }

    static func shortTitle(_ line: String, now: Date, calendar: Calendar) -> String {
        var text = line
        if let date = DateParser.parse(line, now: now, calendar: calendar) {
            text = (line as NSString).replacingCharacters(in: date.range, with: "")
        }
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
        return text.count > 22 ? String(text.prefix(21)) + "…" : text
    }

    static func endOfWeek(_ today: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: today)   // 1 = Sunday
        return calendar.date(byAdding: .day, value: (8 - weekday) % 7, to: today)!
    }

    static func section(of entry: BoardEntry, now: Date, calendar: Calendar) -> (BoardSection, late: Bool) {
        let today = TaskClock.logicalToday(now: now, calendar: calendar)
        if !entry.task.info.isTicked, entry.date.repeatRule == nil,
           Urgency(due: entry.date.due, now: now, calendar: calendar) == .overdue {
            return (.today, true)
        }
        let day = entry.date.due.startOfDay(calendar)
        if day <= today { return (.today, false) }
        if day == calendar.date(byAdding: .day, value: 1, to: today)! { return (.tomorrow, false) }
        if day <= endOfWeek(today, calendar: calendar) { return (.week, false) }
        return (.later, false)
    }

    // MARK: Building

    static var titleFont: NSFont { NSFont(name: "Helvetica-Bold", size: 17) ?? .boldSystemFont(ofSize: 17) }

    /// "Monday 12 October".
    static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_GB")
        format.dateFormat = "EEEE d MMMM"
        return format.string(from: day)
    }

    /// The punch card: one hole per task of the day, punched in its sticky's color as you finish it.
    static func counter(notes: [BoardNote], openToday: Int, now: Date, calendar: Calendar) -> String {
        let today = TaskClock.logicalToday(now: now, calendar: calendar)
        func isToday(_ date: Date) -> Bool { TaskClock.logicalToday(now: date, calendar: calendar) == today }
        var done: [(Date, StickyColor)] = []
        for note in notes {
            for line in note.text.lineInfos() where line.isTicked {
                let when = Date(timeIntervalSinceReferenceDate: line.checklist!)
                if isToday(when) { done.append((when, note.color)) }
            }
            for when in note.doneToday where isToday(when) { done.append((when, note.color)) }
        }
        let colors = done.sorted { $0.0 < $1.0 }.map(\.1.rawValue).joined(separator: ",")
        return "\(colors)|\(openToday)"
    }

    static let calendarDays = 21

    /// The calendar grid: three weeks from this Monday. Per day "2026-10-15;yellow,purple;late;selected".
    static func calendarData(_ entries: [BoardEntry], late: Int, colors: [UUID: StickyColor], selected: Date?,
                             now: Date, calendar: Calendar) -> String {
        let today = TaskClock.logicalToday(now: now, calendar: calendar)
        let weekday = calendar.component(.weekday, from: today)   // 1 = Sunday
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        var cells: [String] = []
        for offset in 0..<calendarDays {
            let day = calendar.date(byAdding: .day, value: offset, to: monday)!
            let due = entries.filter { !$0.task.info.isTicked && $0.date.due.startOfDay(calendar) == day && $0.date.repeatRule == nil }
            let dots = due.map { colors[$0.noteID]?.rawValue ?? "yellow" }.joined(separator: ",")
            let lateHere = day == today ? late : 0
            cells.append("\(DueDate(day: day, calendar: calendar).key);\(dots);\(lateHere);\(day == selected ? 1 : 0)")
        }
        return cells.joined(separator: "|")
    }

    static func build(notes: [BoardNote], today todayEvents: [BoardEvent], tomorrow tomorrowEvents: [BoardEvent],
                      open: Set<String>, foldedGroups: Set<String> = [], calendarOn: Bool = false, selectedDay: Date? = nil,
                      now: Date, calendar: Calendar) -> Result {
        let all = entries(notes: notes, now: now, calendar: calendar)
        let colors = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.color) })
        let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.title) })
        var late: [BoardEntry] = []
        var bySection: [BoardSection: [BoardEntry]] = [:]
        var picked: [BoardEntry] = []   // the day clicked in the calendar
        for entry in all {
            let (section, isLate) = section(of: entry, now: now, calendar: calendar)
            if isLate { late.append(entry); continue }
            if calendarOn, let selectedDay, entry.date.due.startOfDay(calendar) == selectedDay, entry.date.repeatRule == nil {
                picked.append(entry)   // shown once, under the calendar, not again in its usual section
                continue
            }
            bySection[section, default: []].append(entry)
        }
        /// Earlier days first; on the same day tasks with a time first, then sticky order.
        func byTime(_ a: BoardEntry, _ b: BoardEntry) -> Bool {
            let da = (a.date.due.year, a.date.due.month, a.date.due.day)
            let db = (b.date.due.year, b.date.due.month, b.date.due.day)
            if da != db { return da < db }
            let ka = (a.date.due.minute ?? Int.max, a.noteIndex, a.task.info.range.location)
            let kb = (b.date.due.minute ?? Int.max, b.noteIndex, b.task.info.range.location)
            return ka < kb
        }
        late.sort(by: byTime)

        /// A section's tasks by sticky: each group earliest first, groups by their most urgent task.
        func groups(_ list: [BoardEntry]) -> [[BoardEntry]] {
            var byNote: [UUID: [BoardEntry]] = [:]
            for e in list { byNote[e.noteID, default: []].append(e) }
            return byNote.values.map { $0.sorted(by: byTime) }.sorted { byTime($0[0], $1[0]) }
        }

        let out = NSMutableAttributedString()
        var mirrors: [String: BoardMirror] = [:]
        let openToday = late.count + (bySection[.today] ?? []).filter { !$0.task.info.isTicked }.count

        func paragraph(_ content: NSAttributedString, _ attrs: [NSAttributedString.Key: Any]) {
            // the line's own state comes only from `attrs`, never from where the text came from
            let line = NSMutableAttributedString(attributedString: BoardController.plain(content))
            line.append(NSAttributedString(string: "\n"))
            line.addAttributes(attrs, range: NSRange(location: 0, length: line.length))
            if content.length == 0 {
                line.addAttributes([.font: ChecklistTextView.defaultFont], range: NSRange(location: 0, length: line.length))
            }
            out.append(line)
        }

        func style(level: Int, checkbox: Bool, before: CGFloat = 0, after: CGFloat = 1) -> NSParagraphStyle {
            let s = ChecklistTextView.indentStyle(nil, level: level, checkbox: checkbox).mutableCopy() as! NSMutableParagraphStyle
            s.tailIndent = -70
            s.paragraphSpacingBefore = before
            s.paragraphSpacing = after
            return s
        }

        func task(_ line: BoardEntry.Line, entry: BoardEntry, label: String?, spaceBefore: CGFloat) {
            var attrs: [NSAttributedString.Key: Any] = [.boardColor: colors[entry.noteID]?.rawValue ?? "yellow",
                                                        .boardGroup: entry.noteID.uuidString]
            if line.relativeLevel > 0 { attrs[.taskLevel] = NSNumber(value: line.relativeLevel) }
            guard let id = line.info.id else {   // plain text under a task
                attrs[.paragraphStyle] = style(level: line.relativeLevel, checkbox: false)
                attrs[.boardRole] = "note"
                paragraph(line.content, attrs)
                return
            }
            attrs[.paragraphStyle] = style(level: line.relativeLevel, checkbox: true, before: spaceBefore)
            attrs[.boardRole] = "task"
            attrs[.taskID] = id
            attrs[.checklist] = NSNumber(value: line.info.checklist ?? 0)
            if line.info.folded { attrs[.taskFolded] = NSNumber(value: true) }
            if line.info.moved > 0 { attrs[.taskMoved] = NSNumber(value: line.info.moved) }
            if let due = line.due { attrs[.taskDue] = due }
            if let label { attrs[.boardLabel] = label }
            if line.relativeLevel == 0, let progress = entry.progress { attrs[.boardProgress] = progress }
            paragraph(line.content, attrs)
            mirrors[id] = BoardMirror(noteID: entry.noteID, content: line.content.string, checklist: line.info.checklist ?? 0,
                                      folded: line.info.folded, due: line.due, moved: line.info.moved)
        }

        /// One entry and its undated subtasks. `label`: shown at the right of its first line.
        func entry(_ e: BoardEntry, label: String?, spaceBefore: CGFloat) {
            task(e.task, entry: e, label: label, spaceBefore: spaceBefore)
            for child in e.children { task(child, entry: e, label: nil, spaceBefore: 0) }
        }

        func group(_ list: [BoardEntry]) {
            let id = list[0].noteID
            let name = titles[id] ?? ""
            if foldedGroups.contains(id.uuidString) {
                let text = NSMutableAttributedString(string: name.isEmpty ? "Untitled" : name,
                                                     attributes: [.font: countFont, .foregroundColor: quiet])
                text.append(NSAttributedString(string: "  \(list.count)", attributes: [.font: countFont, .foregroundColor: quiet]))
                paragraph(text, [.paragraphStyle: style(level: 0, checkbox: true, before: 6), .boardRole: "group",
                                 .boardGroup: id.uuidString, .boardColor: colors[id]?.rawValue ?? "yellow",
                                 .taskFolded: NSNumber(value: true)])
                return
            }
            for (i, e) in list.enumerated() {
                // a dated subtask keeps its parent's name; otherwise the sticky's name on the group's first line
                let label = e.label != name ? e.label : (i == 0 ? name : nil)
                entry(e, label: label, spaceBefore: i == 0 ? 6 : 0)
            }
        }

        func events(_ list: [BoardEvent]) {
            let timeFormat = DateFormatter()
            timeFormat.dateFormat = "HH:mm"
            timeFormat.timeZone = calendar.timeZone
            for (i, event) in list.sorted(by: { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }).enumerated() {
                let text = NSMutableAttributedString(string: event.allDay ? "all day" : timeFormat.string(from: event.start),
                                                     attributes: [.font: countFont, .foregroundColor: quiet])
                text.append(NSAttributedString(string: "  " + event.title,
                                               attributes: [.font: ChecklistTextView.defaultFont, .foregroundColor: NSColor.black]))
                var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style(level: 0, checkbox: true, before: i == 0 ? 6 : 0),
                                                            .boardRole: "event"]
                if !event.allDay, event.end <= now { attrs[.boardEventEnded] = NSNumber(value: true) }
                paragraph(text, attrs)
            }
        }

        func slot() {
            paragraph(NSAttributedString(), [.paragraphStyle: style(level: 0, checkbox: true, before: 4),
                                             .boardRole: "slot", .checklist: NSNumber(value: 0),
                                             .foregroundColor: NSColor.black])
        }

        // Today: the date as the title, the punch card, late tasks, events, then each sticky's group
        let today = TaskClock.logicalToday(now: now, calendar: calendar)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 1
        paragraph(NSAttributedString(string: dayTitle(today, calendar: calendar), attributes: [.font: titleFont, .foregroundColor: NSColor.black]),
                  [.paragraphStyle: titleStyle, .boardRole: "header:today"])
        let counterStyle = NSMutableParagraphStyle()
        counterStyle.minimumLineHeight = 15
        counterStyle.maximumLineHeight = 15
        counterStyle.paragraphSpacing = 2
        paragraph(NSAttributedString(), [.paragraphStyle: counterStyle, .boardRole: "counter",
                                         .boardCounter: counter(notes: notes, openToday: openToday, now: now, calendar: calendar)])
        if calendarOn {
            let gridStyle = NSMutableParagraphStyle()
            let rows = CGFloat(calendarDays / 7)
            gridStyle.minimumLineHeight = 14 + rows * 30
            gridStyle.maximumLineHeight = 14 + rows * 30
            gridStyle.paragraphSpacing = 4
            paragraph(NSAttributedString(), [.paragraphStyle: gridStyle, .boardRole: "calendar",
                                             .boardCounter: calendarData(all, late: late.count, colors: colors, selected: selectedDay,
                                                                         now: now, calendar: calendar)])
            if let selectedDay {
                let header = NSMutableParagraphStyle()
                header.paragraphSpacingBefore = 4
                header.paragraphSpacing = 1
                paragraph(NSAttributedString(string: dayTitle(selectedDay, calendar: calendar),
                                             attributes: [.font: headerFont, .foregroundColor: NSColor.black]),
                          [.paragraphStyle: header, .boardRole: "header:day:\(DueDate(day: selectedDay, calendar: calendar).key)"])
                groups(picked).forEach(group)
                slot()
            }
        }
        for (i, e) in late.enumerated() { entry(e, label: e.label, spaceBefore: i == 0 ? 4 : 0) }
        events(todayEvents)
        groups(bySection[.today] ?? []).forEach(group)
        slot()

        // the other days: open ones as sections, closed ones in one line at the bottom
        var closed: [(BoardSection, Int)] = []
        for section in [BoardSection.tomorrow, .week, .later] {
            let list = bySection[section] ?? []
            let sectionEvents = section == .tomorrow ? tomorrowEvents : []
            guard open.contains(section.rawValue) else {
                closed.append((section, list.count + sectionEvents.count))
                continue
            }
            let header = NSMutableParagraphStyle()
            header.paragraphSpacingBefore = 12
            header.paragraphSpacing = 1
            paragraph(NSAttributedString(string: section.title, attributes: [.font: headerFont, .foregroundColor: NSColor.black]),
                      [.paragraphStyle: header, .boardRole: "header:\(section.rawValue)"])
            events(sectionEvents)
            groups(list).forEach(group)
            slot()
        }
        if !closed.isEmpty {
            let footer = NSMutableAttributedString()
            for (i, (section, count)) in closed.enumerated() {
                if i > 0 { footer.append(NSAttributedString(string: "  ·  ", attributes: [.font: countFont, .foregroundColor: quiet])) }
                footer.append(NSAttributedString(string: count > 0 ? "\(section.title) \(count)" : section.title,
                                                 attributes: [.font: countFont, .foregroundColor: quiet,
                                                              .boardSectionLink: section.rawValue]))
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 12
            paragraph(footer, [.paragraphStyle: style, .boardRole: "footer"])
        }
        // the last line needs no newline unless it's an empty slot
        if out.length > 0, (out.attribute(.boardRole, at: out.length - 1, effectiveRange: nil) as? String) != "slot" {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }

        return Result(text: out, mirrors: mirrors, openToday: openToday, overdue: late.count)
    }
}
