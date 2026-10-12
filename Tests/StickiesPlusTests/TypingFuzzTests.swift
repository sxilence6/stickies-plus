import AppKit
import XCTest
@testable import StickiesPlusKit

/// Random user-like editing on the real text view. After every typed letter: it must sit right
/// after the previous one, on a line you can see ("letters under each other" = it didn't).
final class TypingFuzzTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func makeView() -> (NSWindow, ChecklistTextView) {
        _ = NSApplication.shared
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Prague")!
        let clock = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 14))!
        let (storage, container) = makeTextSystem(width: 400)
        let tv = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        tv.ownedStorage = storage
        configureScrollingTextView(tv, height: 300)
        tv.isRichText = true
        tv.allowsUndo = true
        tv.calendar = cal
        tv.now = { clock }
        storage.delegate = tv
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.typingAttributes = [.font: ChecklistTextView.defaultFont, .foregroundColor: NSColor.black]
        return (window, tv)
    }

    /// Returns a description of the first broken invariant, or nil.
    private func run(seed: UInt64, steps: Int) -> String? {
        var rng = RNG(state: seed)
        let (window, tv) = makeView()
        defer { window.close() }
        var log: [String] = []
        func pick(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        func typeLetters(_ word: String) -> String? {
            for ch in word {
                let before = tv.selectedRange()
                tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
                let after = tv.selectedRange()
                let s = tv.string as NSString
                if after.location != before.location + 1 - before.length || after.location == 0
                    || s.substring(with: NSRange(location: after.location - 1, length: 1)) != String(ch) {
                    return "typed '\(ch)' but caret went \(before.location)→\(after.location)"
                }
                if tv.isHidden(after.location - 1) { return "typed '\(ch)' into folded-away text" }
            }
            return nil
        }
        for step in 0..<steps {
            let length = (tv.string as NSString).length
            switch pick(14) {
            case 0, 1, 2:
                let word = ["mix", "a", "kick", "Shotlist", "t", "M"][pick(6)]
                log.append("type \(word)")
                if let e = typeLetters(word) { return "seed \(seed) step \(step): \(e)\n  " + log.suffix(25).joined(separator: "\n  ") }
            case 3:
                let word = [" fri", " tomorrow", " wed 10:00", " 14.10", " every day"][pick(5)]
                log.append("type date\(word)")
                if let e = typeLetters(word) { return "seed \(seed) step \(step): \(e)\n  " + log.suffix(25).joined(separator: "\n  ") }
            case 4, 5: log.append("return"); tv.insertNewline(nil)
            case 6: log.append("tab"); tv.insertTab(nil)
            case 7: log.append("shift-tab"); tv.insertBacktab(nil)
            case 8: log.append("backspace"); tv.deleteBackward(nil)
            case 9: log.append("checklist"); tv.toggleChecklist(nil)
            case 10:
                let lines = tv.textStorage!.lineInfos()
                let parents = lines.indices.filter { !descendants(of: $0, in: lines).isEmpty && !tv.isHidden(lines[$0].range.location) }
                if let i = parents.randomElement(using: &rng) { log.append("fold line \(i)"); tv.toggleFold(paragraph: lines[i].range) }
            case 11:
                let tasks = tv.textStorage!.lineInfos().filter { $0.isTask && !tv.isHidden($0.range.location) }
                if let t = tasks.randomElement(using: &rng) { log.append("tick"); tv.toggleCheckbox(paragraph: t.range) }
            case 12:
                let target = length == 0 ? 0 : pick(length + 1)
                log.append("click \(target)"); tv.setSelectedRange(NSRange(location: target, length: 0))
            default:
                log.append("click end"); tv.setSelectedRange(NSRange(location: length, length: 0))
            }
            flush()
        }
        return nil
    }

    func testTypedLettersStayTogether() {
        var failures: [String] = []
        let seeds = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEEDS"] ?? "") ?? 150
        let steps = Int(ProcessInfo.processInfo.environment["FUZZ_STEPS"] ?? "") ?? 120
        for seed in UInt64(1)...seeds {
            if let failure = run(seed: seed, steps: steps) { failures.append(failure) }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(seeds) runs broke. First:\n\(failures.first ?? "")")
    }

    func testTextAfterADateKeepsItsSize() {
        let (window, tv) = makeView()
        defer { window.close() }
        tv.toggleChecklist(nil)
        tv.insertText("finish script wed 10:00", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertNewline(nil)                       // leaving the line fixes the date in 10 pt
        flush()
        tv.insertText("Shotlist", replacementRange: NSRange(location: NSNotFound, length: 0))
        let s = tv.string as NSString
        let font = tv.textStorage!.attribute(.font, at: s.range(of: "Shotlist").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 12, "the new line must not inherit the small date size")
        // typing more on the dated line itself, after its date
        tv.setSelectedRange(NSRange(location: s.range(of: "Wed 14 Oct 10:00").location + "Wed 14 Oct 10:00".count, length: 0))
        tv.insertText(" x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let x = (tv.string as NSString).range(of: " x").location + 1
        XCTAssertEqual((tv.textStorage!.attribute(.font, at: x, effectiveRange: nil) as? NSFont)?.pointSize, 12)
    }
}

extension TypingFuzzTests {
    /// The bug you hit: typing at the end of a plain line that isn't the last one sent
    /// every letter to the start of the next line.
    func testTypingAtTheEndOfAMiddleLineStaysOnIt() {
        let (window, tv) = makeView()
        defer { window.close() }
        tv.insertText("Film\nFilm Update\nlast line", replacementRange: NSRange(location: NSNotFound, length: 0))
        let endOfMiddle = ("Film\nFilm Update" as NSString).length
        tv.setSelectedRange(NSRange(location: endOfMiddle, length: 0))
        flush()
        for ch in " 14.10" {
            tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            flush()
        }
        XCTAssertEqual(tv.string, "Film\nFilm Update 14.10\nlast line")
    }
}
