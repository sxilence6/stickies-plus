import AppKit
import XCTest
@testable import StickiesPlusKit

final class AppearanceTests: XCTestCase {
    private func makeView(_ text: NSAttributedString, palette: StickyColor) -> ChecklistTextView {
        _ = NSApplication.shared
        let (storage, container) = makeTextSystem(width: 300)
        let tv = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: container)
        tv.ownedStorage = storage
        storage.delegate = tv
        storage.setAttributedString(text)
        tv.palette = palette
        return tv
    }

    private func screenColor(_ tv: ChecklistTextView, at index: Int) -> NSColor? {
        var range = NSRange(location: 0, length: tv.textStorage!.length)
        return tv.layoutManager(tv.layoutManager!, shouldUseTemporaryAttributes: [:], forDrawingToScreen: true,
                                atCharacterIndex: index, effectiveRange: &range)?[.foregroundColor] as? NSColor
    }

    func testDarkNoteShowsBlackTextLight() {
        let text = NSMutableAttributedString(string: "black\n", attributes: [.foregroundColor: NSColor.black])
        text.append(NSAttributedString(string: "red", attributes: [.foregroundColor: NSColor.red]))
        let tv = makeView(text, palette: .charcoal)
        XCTAssertEqual(screenColor(tv, at: 0), StickyColor.charcoal.text)
        XCTAssertNil(screenColor(tv, at: 6), "text colored on purpose keeps its color")
        tv.palette = .yellow
        XCTAssertNil(screenColor(tv, at: 0), "light notes draw the stored black")
    }

    func testTickedLineFadesInNoteTextColor() {
        let text = NSMutableAttributedString(string: "done", attributes: [.foregroundColor: NSColor.black])
        text.addAttribute(.checklist, value: NSNumber(value: Date().timeIntervalSinceReferenceDate), range: NSRange(location: 0, length: 4))
        for palette in [StickyColor.yellow, .charcoal] {
            let tv = makeView(text, palette: palette)
            let color = try! XCTUnwrap(screenColor(tv, at: 0)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(color.alphaComponent, 0.6)
            XCTAssertEqual(color.redComponent, palette.text.usingColorSpace(.sRGB)!.redComponent, accuracy: 0.01)
        }
    }

    func testScrollerStaysOverlayAndNoteColored() {
        let view = StickyScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.scrollerStyle = .legacy   // what macOS asks for when a mouse is plugged in
        XCTAssertEqual(view.scrollerStyle, .overlay)
        view.palette = .slate
        XCTAssertEqual((view.verticalScroller as? StickyScroller)?.palette, .slate)
    }

    func testNewColorsSaveAndLoad() throws {
        XCTAssertEqual(Set(StickyColor.allCases.map(\.rawValue)).count, 11)
        XCTAssertEqual(StickyColor.allCases.filter(\.isStickiesOriginal), [.yellow, .blue, .green, .pink, .purple, .gray])
        var meta = NoteMeta()
        meta.color = .graphite
        let data = try JSONEncoder().encode(meta)
        XCTAssertEqual(try JSONDecoder().decode(NoteMeta.self, from: data).color, .graphite)
        XCTAssertEqual(StickyColor.nearest(to: NSColor(white: 1, alpha: 1)), .white)
    }
}
