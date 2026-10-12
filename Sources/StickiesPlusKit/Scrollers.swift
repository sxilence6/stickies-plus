import AppKit

/// No white track: the knob is a thin rectangle in a darker shade of the note.
final class StickyScroller: NSScroller {
    static let knobWidth: CGFloat = 5

    var palette: StickyColor = .yellow { didSet { needsDisplay = true } }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 4 else { return }
        palette.knob.setFill()
        NSRect(x: (knob.midX - Self.knobWidth / 2).rounded(), y: knob.minY + 2,
               width: Self.knobWidth, height: knob.height - 4).fill()
    }
}

/// Stickies' scroll view: overlay scrollers only (so a plugged-in mouse doesn't
/// add a white bar) and the note-colored knob above.
class StickyScrollView: NSScrollView {
    var palette: StickyColor = .yellow {
        didSet { (verticalScroller as? StickyScroller)?.palette = palette }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        verticalScroller = StickyScroller()
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
