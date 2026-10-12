import AppKit

struct DoneItem: Codable, Equatable {
    var text: String
    var finishedAt: Date
}

/// What a line carries besides its text, saved by paragraph number next to the
/// RTFD text (RTF itself has nowhere to keep it). Empty fields are left out of the JSON.
struct ChecklistMark: Codable, Equatable {
    var p: Int              // paragraph index in content.rtfd
    var t: Double? = nil    // checkbox: 0 = open, otherwise the tick time (seconds since 2001-01-01)
    var id: String? = nil   // task id
    var l: Int? = nil       // indent level
    var f: Bool? = nil      // folded
    var d: String? = nil    // last committed date (DueDate.key)
    var m: Int? = nil       // times moved while late

    var isEmpty: Bool { t == nil && id == nil && (l ?? 0) == 0 && f != true && d == nil && (m ?? 0) == 0 }
}

struct NoteMeta: Codable {
    var id: UUID
    var color: StickyColor = .yellow
    var frame = ""
    var expandedHeight: CGFloat?
    var collapsed = false
    var floating = false
    var translucent = false
    var created = Date()
    var modified = Date()
    var order = 0
    var isBoard = false      // the day board (main sticky)
    var fontsRepaired = false   // the leaked-date-size repair has run on this note
    var boardOpen: [String] = ["today"]   // day board sections that are unfolded
    var boardFoldedGroups: [String] = []   // stickies (ids) whose group is folded on the board
    var boardCalendar = false              // the calendar grid is showing
    var checklist: [ChecklistMark] = []
    var done: [DoneItem] = []   // newest first

    init(id: UUID = UUID()) { self.id = id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        color = (try? c.decodeIfPresent(StickyColor.self, forKey: .color)) ?? .yellow
        frame = (try? c.decodeIfPresent(String.self, forKey: .frame)) ?? ""
        expandedHeight = try? c.decodeIfPresent(CGFloat.self, forKey: .expandedHeight)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        floating = (try? c.decodeIfPresent(Bool.self, forKey: .floating)) ?? false
        translucent = (try? c.decodeIfPresent(Bool.self, forKey: .translucent)) ?? false
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
        modified = (try? c.decodeIfPresent(Date.self, forKey: .modified)) ?? created
        order = (try? c.decodeIfPresent(Int.self, forKey: .order)) ?? 0
        isBoard = (try? c.decodeIfPresent(Bool.self, forKey: .isBoard)) ?? false
        fontsRepaired = (try? c.decodeIfPresent(Bool.self, forKey: .fontsRepaired)) ?? false
        boardOpen = (try? c.decodeIfPresent([String].self, forKey: .boardOpen)) ?? ["today"]
        boardFoldedGroups = (try? c.decodeIfPresent([String].self, forKey: .boardFoldedGroups)) ?? []
        boardCalendar = (try? c.decodeIfPresent(Bool.self, forKey: .boardCalendar)) ?? false
        checklist = (try? c.decodeIfPresent([ChecklistMark].self, forKey: .checklist)) ?? []
        done = (try? c.decodeIfPresent([DoneItem].self, forKey: .done)) ?? []
    }
}

enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    /// How long a ticked task stays on the note. 13 hours unless overridden
    /// (`defaults write com.matteoruggiero.stickiesplus DoneDelaySeconds 20` for testing).
    static var doneDelay: TimeInterval {
        let value = defaults.double(forKey: "DoneDelaySeconds")
        return value > 0 ? value : 13 * 3600
    }

    static var defaultColor: StickyColor {
        get { StickyColor(rawValue: defaults.string(forKey: "DefaultColor") ?? "") ?? .yellow }
        set { defaults.set(newValue.rawValue, forKey: "DefaultColor") }
    }

    static var defaultFont: NSFont {
        get {
            if let name = defaults.string(forKey: "DefaultFontName"),
               let font = NSFont(name: name, size: max(defaults.double(forKey: "DefaultFontSize"), 6)) {
                return font
            }
            return NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        }
        set {
            defaults.set(newValue.fontName, forKey: "DefaultFontName")
            defaults.set(Double(newValue.pointSize), forKey: "DefaultFontSize")
        }
    }

    static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: NSColor.black]
    }

    /// Window > Arrange By > When Arranging: 0 = leave as is, 1 = collapse all, 2 = expand all.
    static var collapseWhenArranging: Int {
        get { defaults.integer(forKey: "CollapseWhenArranging") }
        set { defaults.set(newValue, forKey: "CollapseWhenArranging") }
    }
}

enum NoteStore {
    private static var fm: FileManager { .default }

    static var root: URL {
        if let custom = UserDefaults.standard.string(forKey: "DataDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stickies+", isDirectory: true)
    }

    static var notesDir: URL { root.appendingPathComponent("Notes", isDirectory: true) }

    static func folder(for id: UUID) -> URL {
        notesDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func loadAll() -> [(NoteMeta, NSAttributedString)] {
        guard let dirs = try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var notes: [(NoteMeta, NSAttributedString)] = []
        for dir in dirs where dir.hasDirectoryPath {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("note.json")),
                  let meta = try? decoder.decode(NoteMeta.self, from: data) else { continue }
            notes.append((meta, readRTFD(dir.appendingPathComponent("content.rtfd"))))
        }
        return notes
    }

    static func save(_ meta: NoteMeta, text: NSAttributedString) throws {
        let dir = folder(for: meta.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let range = NSRange(location: 0, length: text.length)
        if let wrapper = text.rtfdFileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            try wrapper.write(to: dir.appendingPathComponent("content.rtfd"), options: .atomic, originalContentsURL: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: dir.appendingPathComponent("note.json"), options: .atomic)
    }

    /// Deleted notes go to the Trash, not into the void.
    static func trash(_ id: UUID) {
        let dir = folder(for: id)
        guard fm.fileExists(atPath: dir.path) else { return }
        try? fm.trashItem(at: dir, resultingItemURL: nil)
    }

    private static func readRTFD(_ url: URL) -> NSAttributedString {
        (try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil))
            ?? NSAttributedString()
    }

    // MARK: Apple Stickies import

    static var appleStickiesDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "AppleStickiesDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Stickies/Data/Library/Stickies", isDirectory: true)
    }

    /// Reads Apple Stickies' notes (read-only). Returns nil if Stickies' data can't be read.
    static func readAppleStickies() -> [(NoteMeta, NSAttributedString)]? {
        let dir = appleStickiesDir
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(".SavedStickiesState")),
              let states = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return nil }

        var notes: [(NoteMeta, NSAttributedString)] = []
        for (index, state) in states.enumerated() {
            guard let uuid = state["UUID"] as? String, let id = UUID(uuidString: uuid) else { continue }
            let rtfd = dir.appendingPathComponent("\(uuid).rtfd")
            var meta = NoteMeta(id: id)
            let frame = NSRectFromString(state["Frame"] as? String ?? "")
            let expanded = NSSizeFromString(state["ExpandedSize"] as? String ?? "")
            meta.frame = NSStringFromRect(frame)
            if frame.height < 20, expanded.height > 20 {
                meta.collapsed = true
                meta.expandedHeight = expanded.height
            }
            if let c = state["StickyColor"] as? [String: Any],
               let r = c["Red"] as? Double, let g = c["Green"] as? Double, let b = c["Blue"] as? Double {
                meta.color = StickyColor.nearest(to: NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
            }
            meta.floating = state["Floating"] as? Bool ?? false
            meta.translucent = state["Translucent"] as? Bool ?? false
            let attributes = try? fm.attributesOfItem(atPath: rtfd.path)
            meta.created = attributes?[.creationDate] as? Date ?? Date()
            meta.modified = attributes?[.modificationDate] as? Date ?? meta.created
            meta.order = index
            notes.append((meta, readRTFD(rtfd)))
        }
        return notes
    }
}
