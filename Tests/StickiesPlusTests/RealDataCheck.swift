import AppKit
import XCTest
@testable import StickiesPlusKit

/// Loads a copy of real notes with the current code. REAL_COPY=/path swift test --filter RealDataCheck
final class RealDataCheck: XCTestCase {
    func testLoadsRealNotes() throws {
        guard let path = ProcessInfo.processInfo.environment["REAL_COPY"] else { throw XCTSkip("set REAL_COPY") }
        _ = NSApplication.shared
        UserDefaults.standard.set(path, forKey: "DataDir")
        defer { UserDefaults.standard.removeObject(forKey: "DataDir") }
        let loaded = NoteStore.loadAll()
        let notes = loaded.map { StickyController(meta: $0.0, text: $0.1) }
        if ProcessInfo.processInfo.environment["REAL_COPY_SAVE"] != nil { notes.forEach { $0.saveNow() } }   // writes into the copy only
        var tasks = 0, dated = 0, lines = 0
        for (note, (meta, text)) in zip(notes, loaded) {
            XCTAssertEqual(Set(note.textView.string.components(separatedBy: "\n")), Set(text.string.components(separatedBy: "\n")), "same lines on load (sorting may reorder them, sizes may be repaired)")
            let infos = note.textView.textStorage!.lineInfos()
            lines += infos.count
            tasks += infos.filter(\.isTask).count
            dated += infos.filter { $0.isTask && note.textView.taskDate(of: $0.range) != nil }.count
            XCTAssertEqual(infos.filter(\.isTask).count, meta.checklist.filter { $0.t != nil }.count, "every checkbox survived")
            XCTAssertTrue(infos.filter(\.isTask).allSatisfy { $0.id != nil }, "old checkboxes got ids")
        }
        var boardMeta = NoteMeta()
        boardMeta.isBoard = true
        let board = BoardController(sticky: StickyController(meta: boardMeta, text: NSAttributedString()))
        board.notes = { notes }
        board.rebuild()
        print("REALCHECK notes=\(notes.count) lines=\(lines) tasks=\(tasks) dated=\(dated) boardLines=\(board.textView.string.components(separatedBy: "\n").count)")
        notes.forEach { $0.window.close() }
    }
}
