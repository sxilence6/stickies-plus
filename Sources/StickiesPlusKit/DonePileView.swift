import AppKit

extension NSAttributedString.Key {
    static let doneItem = NSAttributedString.Key("StickiesPlusDoneItem")
}

/// The back of the note: everything finished on this sticky, newest first, grouped by day.
final class DonePileView: StickyScrollView {
    let textView: DoneTextView
    private let ownedStorage: NSTextStorage

    weak var controller: StickyController? {
        didSet { textView.controller = controller }
    }

    override init(frame: NSRect) {
        let (storage, container) = makeTextSystem(width: frame.width)
        ownedStorage = storage
        textView = DoneTextView(frame: NSRect(origin: .zero, size: frame.size), textContainer: container)
        super.init(frame: frame)
        configureScrollingTextView(textView, height: frame.height)
        textView.isEditable = false
        textView.isSelectable = true
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reload(items: [DoneItem], title: String, palette: StickyColor, delay: TimeInterval) {
        let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let bold = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)
        let small = NSFont(name: "Helvetica", size: 10) ?? .systemFont(ofSize: 10)
        let smallBold = NSFont(name: "Helvetica-Bold", size: 10) ?? .boldSystemFont(ofSize: 10)
        let ink = palette.text
        self.palette = palette
        let hanging = NSMutableParagraphStyle()
        let checkWidth = ("✓ " as NSString).size(withAttributes: [.font: font]).width
        hanging.headIndent = checkWidth
        hanging.paragraphSpacing = 2

        let text = NSMutableAttributedString()
        func add(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        add(title.isEmpty ? "Done\n" : "Done · \(title)\n", [.font: bold, .foregroundColor: ink])

        if items.isEmpty {
            add("\nNothing here yet.\nTicked tasks move here \(Self.describe(delay)) after you tick them.\n",
                [.font: font, .foregroundColor: ink.withAlphaComponent(0.45)])
        } else {
            let day = DateFormatter()
            day.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
            let time = DateFormatter()
            time.setLocalizedDateFormatFromTemplate("jj:mm")
            let calendar = Calendar.current
            var currentDay: Date?
            for (index, item) in items.enumerated() {
                let itemDay = calendar.startOfDay(for: item.finishedAt)
                if itemDay != currentDay {
                    currentDay = itemDay
                    add("\n", [.font: small])
                    add(day.string(from: item.finishedAt) + "\n", [.font: smallBold, .foregroundColor: ink.withAlphaComponent(0.55)])
                }
                let line: [NSAttributedString.Key: Any] = [.paragraphStyle: hanging, .doneItem: index]
                add("✓ ", line.merging([.font: font, .foregroundColor: palette.highlight]) { $1 })
                add(item.text, line.merging([.font: font, .foregroundColor: ink]) { $1 })
                add("  " + time.string(from: item.finishedAt) + "\n",
                    line.merging([.font: small, .foregroundColor: ink.withAlphaComponent(0.45)]) { $1 })
            }
        }
        textView.textStorage?.setAttributedString(text)
    }

    static func describe(_ delay: TimeInterval) -> String {
        if delay >= 3600, delay.truncatingRemainder(dividingBy: 3600) == 0 {
            let hours = Int(delay / 3600)
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if delay >= 60, delay.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(delay / 60)) minutes" }
        return "\(Int(delay)) seconds"
    }
}

final class DoneTextView: NSTextView {
    weak var controller: StickyController?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let length = textStorage?.length ?? 0
        if length > 0 {
            let index = min(characterIndexForInsertion(at: point), length - 1)
            if let item = textStorage?.attribute(.doneItem, at: index, effectiveRange: nil) as? Int {
                menu.addItem(withTitle: "Put Back on Note", action: #selector(putBack(_:)), keyEquivalent: "").representedObject = item
                menu.addItem(withTitle: "Remove from Done Pile", action: #selector(remove(_:)), keyEquivalent: "").representedObject = item
                menu.addItem(.separator())
            }
        }
        if !controller.meta.done.isEmpty {
            menu.addItem(withTitle: "Clear Done Pile…", action: #selector(clear(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Note", action: #selector(showNote(_:)), keyEquivalent: "")
        for item in menu.items where item.action != #selector(copy(_:)) { item.target = self }
        return menu
    }

    @objc private func putBack(_ sender: NSMenuItem) { controller?.putBack(sender.representedObject as? Int ?? -1) }
    @objc private func remove(_ sender: NSMenuItem) { controller?.removeDone(sender.representedObject as? Int ?? -1) }
    @objc private func clear(_ sender: Any?) { controller?.clearDone() }
    @objc private func showNote(_ sender: Any?) { controller?.flip() }
}
