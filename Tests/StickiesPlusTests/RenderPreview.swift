import AppKit
import XCTest
@testable import StickiesPlusKit

/// Writes preview PNGs of real note windows. Runs only with RENDER_DIR set:
/// RENDER_DIR=/tmp/out swift test --filter RenderPreview
final class RenderPreview: XCTestCase {
    func testRenderColors() throws {
        guard let out = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set RENDER_DIR") }
        _ = NSApplication.shared
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString)")
        UserDefaults.standard.set(dataDir.path, forKey: "DataDir")
        defer { UserDefaults.standard.removeObject(forKey: "DataDir"); try? FileManager.default.removeItem(at: dataDir) }

        let font = NSFont(name: "Helvetica", size: 12)!, bold = NSFont(name: "Helvetica-Bold", size: 12)!
        let body = ["bounce stems", "fix kick eq", "sidechain bass", "name tracks", "send to anna", "print setlist",
                    "charge batteries", "pack cables", "tune modular", "backup samples", "answer emails", "buy strings"]
        var images: [NSImage] = []
        for color in [StickyColor.yellow, .white, .silver, .slate, .graphite, .charcoal] {
            let text = NSMutableAttributedString(string: "\(color.title)\n", attributes: [.font: bold, .foregroundColor: NSColor.black])
            for (i, line) in body.enumerated() {
                text.append(NSAttributedString(string: line + (i == body.count - 1 ? "" : "\n"),
                                               attributes: [.font: font, .foregroundColor: NSColor.black,
                                                            .paragraphStyle: ChecklistTextView.indented(nil, by: ChecklistTextView.indent)]))
            }
            var meta = NoteMeta()
            meta.color = color
            meta.frame = NSStringFromRect(NSRect(x: 0, y: 0, width: 220, height: 170))
            meta.checklist = (1...body.count).map { ChecklistMark(p: $0, t: $0 == 2 ? Date().timeIntervalSinceReferenceDate - 60 : 0) }
            let note = StickyController(meta: meta, text: text)
            note.window.orderFront(nil)
            if let scrollView = note.textView.enclosingScrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                scrollView.verticalScroller?.alphaValue = 1
            }
            let view = note.window.contentView!
            view.layoutSubtreeIfNeeded()
            images.append(view.snapshot()!)
            note.window.close()
        }
        let gap: CGFloat = 16, w: CGFloat = 220, h: CGFloat = 170
        let sheet = NSImage(size: NSSize(width: (w + gap) * 3 + gap, height: (h + gap) * 2 + gap))
        sheet.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, image) in images.enumerated() {
            let x = gap + CGFloat(i % 3) * (w + gap), y = sheet.size.height - (gap + h) * CGFloat(i / 3 + 1)
            image.draw(in: NSRect(x: x, y: y, width: w, height: h))
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent("colors.png"))
    }
}
