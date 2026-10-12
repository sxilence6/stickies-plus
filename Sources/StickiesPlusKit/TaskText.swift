import AppKit

/// Everything a line can carry besides its text. All are paragraph-wide: the first
/// character of a line decides, the rest of the line follows (see `normalize`).
extension NSAttributedString.Key {
    /// Checkbox. NSNumber: 0 = open, otherwise the tick time (seconds since 2001).
    static let checklist = NSAttributedString.Key("StickiesPlusChecklist")
    /// Hidden task id (String), so the day board can find this line again.
    static let taskID = NSAttributedString.Key("StickiesPlusTaskID")
    /// Indent level (NSNumber Int, 0 = top). Subtasks are deeper levels.
    static let taskLevel = NSAttributedString.Key("StickiesPlusLevel")
    /// The lines under this one are folded away (NSNumber Bool).
    static let taskFolded = NSAttributedString.Key("StickiesPlusFolded")
    /// The last date this task was committed with (DueDate.key), to notice moves.
    static let taskDue = NSAttributedString.Key("StickiesPlusDue")
    /// How many times the date was moved while the task was already late (NSNumber Int).
    static let taskMoved = NSAttributedString.Key("StickiesPlusMoved")

    // Day board only
    /// "header:today", "event", "task", "slot" (empty line for a new task), "new".
    static let boardRole = NSAttributedString.Key("StickiesPlusBoardRole")
    /// Name of the sticky a mirrored task lives in, drawn faded on the right.
    static let boardLabel = NSAttributedString.Key("StickiesPlusBoardLabel")
    /// "2/3" progress of a mirrored parent task (its children may live elsewhere on the board).
    static let boardProgress = NSAttributedString.Key("StickiesPlusBoardProgress")
    /// A calendar event that has already ended (NSNumber Bool).
    static let boardEventEnded = NSAttributedString.Key("StickiesPlusBoardEventEnded")
    /// The sticky a board line comes from (UUID string), for folding its group.
    static let boardGroup = NSAttributedString.Key("StickiesPlusBoardGroup")
    /// That sticky's color (StickyColor raw value), drawn as a bar at the left edge.
    static let boardColor = NSAttributedString.Key("StickiesPlusBoardColor")
    /// The punch card: "purple,yellow|3" = finished tasks' colors in order, then how many are open.
    static let boardCounter = NSAttributedString.Key("StickiesPlusBoardCounter")
    /// A clickable day name in the board's footer (BoardSection raw value). Per character.
    static let boardSectionLink = NSAttributedString.Key("StickiesPlusBoardSectionLink")

    static let paragraphKeys: [NSAttributedString.Key] = [
        .checklist, .taskID, .taskLevel, .taskFolded, .taskDue, .taskMoved,
        .boardRole, .boardLabel, .boardProgress, .boardEventEnded, .boardGroup, .boardColor, .boardCounter,
    ]
    /// Keys that only make sense on a checkbox line.
    static let taskOnlyKeys: [NSAttributedString.Key] = [.taskID, .taskDue, .taskMoved]
}

extension NSString {
    /// Every non-empty paragraph (line + its newline) touching `range`.
    func paragraphRanges(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            result.append(paragraph)
            location = NSMaxRange(paragraph)
        }
        return result
    }

    var allParagraphs: [NSRange] { paragraphRanges(in: NSRange(location: 0, length: length)) }

    /// The paragraph without its newline.
    func contentRange(of paragraph: NSRange) -> NSRange {
        var r = paragraph
        while r.length > 0, isNewline(character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }
}

func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2029 || c == 0x85 }

func newTaskID() -> String { UUID().uuidString }

/// One line of a note, as the checklist and the day board see it.
struct LineInfo {
    var range: NSRange           // with newline
    var content: NSRange         // without newline
    var level: Int
    var checklist: Double?       // nil = not a checkbox
    var id: String?
    var folded: Bool
    var moved: Int

    var isTask: Bool { checklist != nil }
    var isTicked: Bool { (checklist ?? 0) > 0 }
}

extension NSAttributedString {
    func lineInfos() -> [LineInfo] {
        let s = string as NSString
        return s.allParagraphs.map { lineInfo(for: $0, in: s) }
    }

    func lineInfo(for p: NSRange, in s: NSString) -> LineInfo {
        func attr(_ key: NSAttributedString.Key) -> Any? { attribute(key, at: p.location, effectiveRange: nil) }
        return LineInfo(range: p, content: s.contentRange(of: p),
                        level: (attr(.taskLevel) as? NSNumber)?.intValue ?? 0,
                        checklist: (attr(.checklist) as? NSNumber)?.doubleValue,
                        id: attr(.taskID) as? String,
                        folded: (attr(.taskFolded) as? NSNumber)?.boolValue ?? false,
                        moved: (attr(.taskMoved) as? NSNumber)?.intValue ?? 0)
    }
}

/// Indices of the lines nested under `index` (deeper level, right below it).
func descendants(of index: Int, in lines: [LineInfo]) -> Range<Int> {
    var end = index + 1
    while end < lines.count, lines[end].level > lines[index].level { end += 1 }
    return (index + 1)..<end
}

func directChildren(of index: Int, in lines: [LineInfo]) -> [Int] {
    descendants(of: index, in: lines).filter { lines[$0].level == lines[index].level + 1 }
}

func parent(of index: Int, in lines: [LineInfo]) -> Int? {
    var i = index - 1
    while i >= 0 {
        if lines[i].level < lines[index].level { return i }
        i -= 1
    }
    return nil
}

/// Makes every paragraph attribute uniform over its line, gives each checkbox line a
/// unique id, and strips task-only keys from plain lines. `boardMode`: a duplicated
/// line on the board is a new line, not a second mirror.
func normalizeParagraphs(_ storage: NSTextStorage, editedRange: NSRange, boardMode: Bool) {
    let s = storage.string as NSString
    guard s.length > 0 else { return }
    let start = max(0, min(editedRange.location, s.length) - 1)
    let end = min(s.length, NSMaxRange(editedRange) + 1)
    for p in s.paragraphRanges(in: s.paragraphRange(for: NSRange(location: start, length: end - start))) {
        for key in NSAttributedString.Key.paragraphKeys {
            var run = NSRange()
            let value = storage.attribute(key, at: p.location, longestEffectiveRange: &run, in: p)
            guard !NSEqualRanges(run, p) else { continue }
            if let value { storage.addAttribute(key, value: value, range: p) } else { storage.removeAttribute(key, range: p) }
        }
        if storage.attribute(.checklist, at: p.location, effectiveRange: nil) == nil {
            // Only touch the line if it really carries one of these: any edit here, even removing
            // something that isn't there, makes AppKit move the caret to the end of the line.
            for key in NSAttributedString.Key.taskOnlyKeys where has(storage, key, in: p) {
                storage.removeAttribute(key, range: p)
            }
        } else if storage.attribute(.taskID, at: p.location, effectiveRange: nil) == nil, !boardMode {
            storage.addAttribute(.taskID, value: newTaskID(), range: p)
        }
    }
    // first line with an id keeps it; copies (from splitting a line) get a fresh one
    var seen = Set<String>()
    for p in s.allParagraphs {
        guard let id = storage.attribute(.taskID, at: p.location, effectiveRange: nil) as? String else { continue }
        if seen.insert(id).inserted { continue }
        if boardMode {
            for key in [NSAttributedString.Key.taskID, .taskDue, .taskMoved, .boardLabel, .boardProgress] where has(storage, key, in: p) {
                storage.removeAttribute(key, range: p)
            }
            storage.addAttribute(.boardRole, value: "new", range: p)
        } else {
            storage.addAttribute(.taskID, value: newTaskID(), range: p)
            if has(storage, .taskMoved, in: p) { storage.removeAttribute(.taskMoved, range: p) }
        }
    }
}

/// Whether any character of `range` carries `key`.
private func has(_ storage: NSTextStorage, _ key: NSAttributedString.Key, in range: NSRange) -> Bool {
    var found = false
    storage.enumerateAttribute(key, in: range) { value, _, stop in
        if value != nil { found = true; stop.pointee = true }
    }
    return found
}
