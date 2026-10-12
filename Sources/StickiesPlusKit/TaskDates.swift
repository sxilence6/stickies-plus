import Foundation

/// When a task is due: a calendar day, optionally with a time.
struct DueDate: Hashable, Comparable {
    var year: Int, month: Int, day: Int
    var minute: Int?   // minutes after midnight, when a time was written

    init(year: Int, month: Int, day: Int, minute: Int? = nil) {
        self.year = year; self.month = month; self.day = day; self.minute = minute
    }

    init(day date: Date, minute: Int? = nil, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!, minute: minute)
    }

    func startOfDay(_ calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The moment it's late: the written time, or the end of the day (2:00 the next night).
    func deadline(_ calendar: Calendar = .current) -> Date {
        let start = startOfDay(calendar)
        if let minute { return start.addingTimeInterval(TimeInterval(minute * 60)) }
        return calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(TaskClock.dayEndHour * 3600)
    }

    /// Stored form, e.g. "2026-10-16" or "2026-10-16 15:00".
    var key: String {
        let base = String(format: "%04d-%02d-%02d", year, month, day)
        guard let minute else { return base }
        return base + String(format: " %02d:%02d", minute / 60, minute % 60)
    }

    init?(key: String) {
        let parts = key.split(separator: " ")
        let d = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard d.count == 3 else { return nil }
        var minute: Int?
        if parts.count > 1 {
            let t = parts[1].split(separator: ":").compactMap { Int($0) }
            guard t.count == 2 else { return nil }
            minute = t[0] * 60 + t[1]
        }
        self.init(year: d[0], month: d[1], day: d[2], minute: minute)
    }

    /// How a committed date reads on the note: "Fri 16 Oct", "Fri 16 Oct 15:00", "Mon 4 Jan 2027".
    func display(now: Date, calendar: Calendar = .current) -> String {
        let weekday = calendar.component(.weekday, from: startOfDay(calendar))
        var text = "\(DateWords.weekdayShort[weekday - 1]) \(day) \(DateWords.monthShort[month - 1])"
        if year != calendar.component(.year, from: TaskClock.logicalToday(now: now, calendar: calendar)) { text += " \(year)" }
        if let minute { text += String(format: " %02d:%02d", minute / 60, minute % 60) }
        return text
    }

    static func < (a: DueDate, b: DueDate) -> Bool {
        (a.year, a.month, a.day, a.minute ?? -1) < (b.year, b.month, b.day, b.minute ?? -1)
    }
}

enum RepeatRule: Equatable {
    case daily
    case weekly(Int)   // Calendar weekday, 1 = Sunday

    func nextDay(onOrAfter day: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .daily: return day
        case .weekly(let weekday):
            let today = calendar.component(.weekday, from: day)
            return calendar.date(byAdding: .day, value: (weekday - today + 7) % 7, to: day)!
        }
    }
}

/// A date found at the end of a task line.
struct TaskDate: Equatable {
    var range: NSRange          // where the date words are, in the line text
    var due: DueDate            // for repeating tasks: the next time it comes round
    var repeatRule: RepeatRule?

    /// Typed words like "fri" or "zítra" get rewritten to a fixed date once you leave the line,
    /// so "tomorrow" doesn't keep meaning tomorrow forever.
    func needsRewrite(of text: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard repeatRule == nil else { return false }
        let written = (text as NSString).substring(with: range)
        return written.compare(due.display(now: now, calendar: calendar), options: .caseInsensitive) != .orderedSame
    }
}

enum TaskClock {
    /// The day ends at 2:00 at night: until then "today" is still yesterday's date.
    static let dayEndHour: TimeInterval = 2
    /// Tasks warm up toward red over the last 6 hours before their deadline.
    static let warmHours: TimeInterval = 6

    static func logicalToday(now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-dayEndHour * 3600))
    }
}

enum Urgency: Equatable {
    case calm
    case warming(Double)   // 0…1 over the last 6 hours
    case overdue

    init(due: DueDate, now: Date, calendar: Calendar = .current) {
        let deadline = due.deadline(calendar)
        let warmStart = deadline.addingTimeInterval(-TaskClock.warmHours * 3600)
        if now >= deadline {
            self = .overdue
        } else if now >= warmStart {
            self = .warming(now.timeIntervalSince(warmStart) / (TaskClock.warmHours * 3600))
        } else {
            self = .calm
        }
    }

    /// "late", "3 h late", "1 day late", "4 days late".
    static func lateText(due: DueDate, now: Date, calendar: Calendar = .current) -> String {
        let deadline = due.deadline(calendar)
        let days = calendar.dateComponents([.day], from: due.startOfDay(calendar),
                                           to: TaskClock.logicalToday(now: now, calendar: calendar)).day ?? 0
        if due.minute != nil, now.timeIntervalSince(deadline) < 24 * 3600 {
            let hours = Int(now.timeIntervalSince(deadline) / 3600)
            return hours < 1 ? "late" : "\(hours) h late"
        }
        let n = max(days, 1)
        return n == 1 ? "1 day late" : "\(n) days late"
    }
}

enum DateWords {
    static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Folded (lowercase, no accents) word → Calendar weekday (1 = Sunday). English + Czech.
    static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
        "nedele": 1, "nedeli": 1, "pondeli": 2, "utery": 3, "streda": 4, "stredu": 4,
        "ctvrtek": 5, "patek": 6, "sobota": 7, "sobotu": 7,
    ]
    /// Short Czech days only count with their accents (plain "po", "ne", "so" are ordinary words).
    static let czechShortDays: [String: Int] = ["út": 3, "čt": 5, "pá": 6]

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]
}

/// Reads a date written at the end of a task line: "send mix fri", "call 15:00",
/// "release 16 oct", "zítra", "every mon", "každý den 9:00". English first, some Czech.
enum DateParser {
    private struct Token { let raw: String; let word: String; let range: NSRange }

    static func parse(_ line: String, now: Date, calendar: Calendar = .current) -> TaskDate? {
        let tokens = tokenize(line)
        guard tokens.count >= 2 else { return nil }   // a task needs words before its date
        let today = TaskClock.logicalToday(now: now, calendar: calendar)
        for count in stride(from: min(5, tokens.count - 1), through: 1, by: -1) {
            let suffix = Array(tokens[(tokens.count - count)...])
            guard let (due, rule) = match(suffix.map(\.word), raw: suffix.map(\.raw), today: today, calendar: calendar) else { continue }
            let range = NSUnionRange(suffix.first!.range, suffix.last!.range)
            return TaskDate(range: range, due: due, repeatRule: rule)
        }
        return nil
    }

    private static func tokenize(_ line: String) -> [Token] {
        let s = line as NSString
        var tokens: [Token] = []
        var start: Int?
        for i in 0...s.length {
            let isSpace = i == s.length || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(s.character(at: i)) ?? " ")
            if isSpace, let begin = start {
                let range = NSRange(location: begin, length: i - begin)
                let raw = s.substring(with: range).lowercased()
                tokens.append(Token(raw: raw, word: raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil), range: range))
                start = nil
            } else if !isSpace, start == nil {
                start = i
            }
        }
        return tokens
    }

    private static func match(_ words: [String], raw: [String], today: Date, calendar: Calendar) -> (DueDate, RepeatRule?)? {
        var words = words, raw = raw
        // a trailing time, e.g. "15:00" or "3pm"
        var minute: Int?
        if let last = words.last, let m = parseTime(last) {
            minute = m
            words.removeLast(); raw.removeLast()
            if words.isEmpty { return (DueDate(day: today, minute: m, calendar: calendar), nil) }
        }
        // repeating
        if words == ["daily"] || words == ["everyday"] || words == ["denne"] || words == ["every", "day"] || words == ["kazdy", "den"] {
            return (DueDate(day: today, minute: minute, calendar: calendar), .daily)
        }
        if words.count == 2, ["every", "kazdy", "kazde", "kazdou"].contains(words[0]),
           let weekday = DateWords.weekdays[words[1]] ?? DateWords.czechShortDays[raw[1]] {
            let rule = RepeatRule.weekly(weekday)
            return (DueDate(day: rule.nextDay(onOrAfter: today, calendar: calendar), minute: minute, calendar: calendar), rule)
        }
        guard let day = matchDay(words, raw: raw, today: today, calendar: calendar) else { return nil }
        return (DueDate(day: day, minute: minute, calendar: calendar), nil)
    }

    private static func matchDay(_ words: [String], raw: [String], today: Date, calendar: Calendar) -> Date? {
        func add(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today)! }
        func weekday(_ i: Int) -> Int? { DateWords.weekdays[words[i]] ?? DateWords.czechShortDays[raw[i]] }
        let toMonday = (9 - calendar.component(.weekday, from: today)) % 7
        let mondayNextWeek = add(toMonday == 0 ? 7 : toMonday)

        switch words.count {
        case 1:
            switch words[0] {
            case "today", "tod", "dnes": return today
            case "tomorrow", "tmr", "tmrw", "zitra": return add(1)
            default: break
            }
            if let w = weekday(0) { return RepeatRule.weekly(w).nextDay(onOrAfter: today, calendar: calendar) }
            return numericDate(words[0], today: today, calendar: calendar)
        case 2:
            if words == ["next", "week"] || words == ["pristi", "tyden"] { return mondayNextWeek }
            if words[0] == "next" || words[0] == "pristi", let w = weekday(1) {
                return RepeatRule.weekly(w).nextDay(onOrAfter: mondayNextWeek, calendar: calendar)
            }
            if weekday(0) != nil, let d = numericDate(words[1], today: today, calendar: calendar) { return d }
            return dayMonth(words, today: today, calendar: calendar)
        case 3:
            if (words[0] == "in" || words[0] == "za"), let n = Int(words[1]), n >= 0, n < 400,
               ["day", "days", "den", "dny", "dni"].contains(words[2]) { return add(n) }
            if weekday(0) != nil { return dayMonth(Array(words.dropFirst()), today: today, calendar: calendar) }
            return dayMonth(words, today: today, calendar: calendar)
        case 4:
            if weekday(0) != nil { return dayMonth(Array(words.dropFirst()), today: today, calendar: calendar) }
            return nil
        default:
            return nil
        }
    }

    /// "16 oct", "oct 16", "16 october 2027".
    private static func dayMonth(_ words: [String], today: Date, calendar: Calendar) -> Date? {
        guard words.count == 2 || words.count == 3 else { return nil }
        var year: Int?
        if words.count == 3 {
            guard let y = Int(words[2]), (2000...2100).contains(y) else { return nil }
            year = y
        }
        if let d = Int(words[0]), let m = DateWords.months[words[1]] { return makeDate(d, m, year, today, calendar) }
        if let m = DateWords.months[words[0]], let d = Int(words[1]) { return makeDate(d, m, year, today, calendar) }
        return nil
    }

    /// "16.10.", "16.10.2027", "16.10" (both parts two digits), "16/10", "16/10/2027".
    private static func numericDate(_ word: String, today: Date, calendar: Calendar) -> Date? {
        let pattern = #"^(\d{1,2})([./])(\d{1,2})(?:[./](\d{4})?)?$"#
        guard word.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let parts = word.split(whereSeparator: { $0 == "." || $0 == "/" }).map(String.init)
        guard parts.count >= 2, let d = Int(parts[0]), let mo = Int(parts[1]) else { return nil }
        let trailing = word.hasSuffix(".") || word.hasSuffix("/")
        if parts.count == 2, !trailing, parts[0].count < 2 || parts[1].count < 2 { return nil } // "1.2" or "1/2" isn't a date
        let year = parts.count == 3 ? Int(parts[2]) : nil
        return makeDate(d, mo, year, today, calendar)
    }

    /// Without a year: the one closest to today (so "16 mar" in October means next March).
    private static func makeDate(_ day: Int, _ month: Int, _ year: Int?, _ today: Date, _ calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let thisYear = calendar.component(.year, from: today)
        let candidates = year.map { [$0] } ?? [thisYear - 1, thisYear, thisYear + 1]
        let dates = candidates.compactMap { y -> Date? in
            let c = DateComponents(year: y, month: month, day: day)
            guard let date = calendar.date(from: c), calendar.component(.day, from: date) == day else { return nil }
            return date
        }
        return dates.min { abs($0.timeIntervalSince(today)) < abs($1.timeIntervalSince(today)) }
    }

    private static func parseTime(_ word: String) -> Int? {
        if let m = word.range(of: #"^(\d{1,2}):(\d{2})$"#, options: .regularExpression), m.lowerBound == word.startIndex {
            let p = word.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2, p[0] < 24, p[1] < 60 else { return nil }
            return p[0] * 60 + p[1]
        }
        if word.range(of: #"^\d{1,2}(:\d{2})?(am|pm)$"#, options: .regularExpression) != nil {
            let pm = word.hasSuffix("pm")
            let p = word.dropLast(2).split(separator: ":").compactMap { Int($0) }
            guard let h = p.first, (1...12).contains(h) else { return nil }
            let m = p.count > 1 ? p[1] : 0
            guard m < 60 else { return nil }
            return ((h % 12) + (pm ? 12 : 0)) * 60 + m
        }
        return nil
    }
}
