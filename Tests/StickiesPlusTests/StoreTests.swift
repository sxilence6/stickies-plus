import AppKit
import XCTest
@testable import StickiesPlusKit

/// Saving, the 13-hour sweep through a real note, and the Apple Stickies import.
final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StickiesPlusTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set(dir.appendingPathComponent("data").path, forKey: "DataDir")
        UserDefaults.standard.set(50.0, forKey: "DoneDelaySeconds")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "DataDir")
        UserDefaults.standard.removeObject(forKey: "DoneDelaySeconds")
        UserDefaults.standard.removeObject(forKey: "AppleStickiesDir")
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testTickedLineMovesToThisNotesDonePileAndPersists() throws {
        let font = ChecklistTextView.defaultFont
        let text = NSMutableAttributedString(string: "music\nbounce stems\nsidechain bass",
                                             attributes: [.font: font, .foregroundColor: NSColor.black])
        var meta = NoteMeta()
        meta.frame = NSStringFromRect(NSRect(x: 100, y: 100, width: 300, height: 200))
        let tickedAt = Date().addingTimeInterval(-100)
        meta.checklist = [ChecklistMark(p: 1, t: 0), ChecklistMark(p: 2, t: tickedAt.timeIntervalSinceReferenceDate)]
        let note = StickyController(meta: meta, text: text)

        note.tick(now: Date())

        XCTAssertEqual(note.textView.string, "music\nbounce stems")
        XCTAssertEqual(note.meta.done.map(\.text), ["sidechain bass"])
        XCTAssertEqual(note.meta.done[0].finishedAt.timeIntervalSinceReferenceDate, tickedAt.timeIntervalSinceReferenceDate, accuracy: 1)

        let saved = try XCTUnwrap(NoteStore.loadAll().first { $0.0.id == meta.id })
        XCTAssertEqual(saved.1.string, "music\nbounce stems")
        XCTAssertEqual(saved.0.done.map(\.text), ["sidechain bass"])
        XCTAssertEqual(saved.0.checklist.map(\.p), [1])
        XCTAssertEqual(saved.0.checklist.map(\.t), [0])
        XCTAssertNotNil(saved.0.checklist.first?.id)

        note.putBack(0)
        XCTAssertEqual(note.textView.string, "music\nbounce stems\nsidechain bass")
        XCTAssertTrue(note.meta.done.isEmpty)
        XCTAssertEqual(note.meta.checklist.count, 2)
        note.window.close()
    }

    func testUntickedBeforeDeadlineStays() {
        let text = NSAttributedString(string: "a", attributes: [.font: ChecklistTextView.defaultFont])
        var meta = NoteMeta()
        meta.checklist = [ChecklistMark(p: 0, t: Date().addingTimeInterval(-10).timeIntervalSinceReferenceDate)]
        let note = StickyController(meta: meta, text: text)
        note.tick(now: Date())
        XCTAssertEqual(note.textView.string, "a")
        XCTAssertTrue(note.meta.done.isEmpty)
        note.window.close()
    }

    func testImportReadsStickiesState() throws {
        let apple = dir.appendingPathComponent("apple")
        try FileManager.default.createDirectory(at: apple, withIntermediateDirectories: true)
        let id = UUID()
        let text = NSAttributedString(string: "Work\n- edit video", attributes: [.font: ChecklistTextView.defaultFont])
        let wrapper = try XCTUnwrap(text.rtfdFileWrapper(from: NSRange(location: 0, length: text.length),
                                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]))
        try wrapper.write(to: apple.appendingPathComponent("\(id.uuidString).rtfd"), options: .atomic, originalContentsURL: nil)
        let state: [[String: Any]] = [[
            "UUID": id.uuidString,
            "Frame": "{{1554, 658}, {409, 12}}",
            "ExpandedSize": "{409, 346}",
            "Floating": true,
            "Translucent": false,
            "StickyColor": ["Red": 0.713725, "Green": 0.792157, "Blue": 1.0, "Alpha": 1.0],
        ]]
        try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            .write(to: apple.appendingPathComponent(".SavedStickiesState"))
        UserDefaults.standard.set(apple.path, forKey: "AppleStickiesDir")

        let notes = try XCTUnwrap(NoteStore.readAppleStickies())
        XCTAssertEqual(notes.count, 1)
        let (meta, imported) = notes[0]
        XCTAssertEqual(meta.id, id)
        XCTAssertEqual(meta.color, .purple)
        XCTAssertTrue(meta.collapsed)
        XCTAssertEqual(meta.expandedHeight, 346)
        XCTAssertTrue(meta.floating)
        XCTAssertEqual(NSRectFromString(meta.frame), NSRect(x: 1554, y: 658, width: 409, height: 12))
        XCTAssertEqual(imported.string, "Work\n- edit video")
    }

    func testOldOrPartialJSONStillLoads() throws {
        let id = UUID()
        let folder = NoteStore.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(id.uuidString)","color":"pink"}"#.utf8).write(to: folder.appendingPathComponent("note.json"))
        let loaded = try XCTUnwrap(NoteStore.loadAll().first)
        XCTAssertEqual(loaded.0.id, id)
        XCTAssertEqual(loaded.0.color, .pink)
        XCTAssertTrue(loaded.0.done.isEmpty)
    }
}
