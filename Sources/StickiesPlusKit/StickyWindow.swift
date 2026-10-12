import AppKit

/// Stickies' SNWindow: no title bar (style mask closable|miniaturizable|resizable),
/// a 12 pt "spine" on top instead.
final class StickyWindow: NSWindow {
    weak var controller: StickyController?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isRestorable = false
        acceptsMouseMovedEvents = true
        isExcludedFromWindowsMenu = false
        collectionBehavior = [.fullScreenNone]
        appearance = NSAppearance(named: .aqua)   // notes stay paper-colored in Dark Mode, like Stickies
        minSize = NSSize(width: 30, height: 30)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) { controller?.closeNote() }
    override func performZoom(_ sender: Any?) { controller?.zoom() }
    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }

    @objc func performCollapse(_ sender: Any?) { controller?.toggleCollapse() }
    @objc func clickColorMenuItem(_ sender: NSMenuItem) { controller?.setColor(StickyColor.allCases[sender.tag]) }
    @objc func toggleFloatingMenuAction(_ sender: Any?) { controller?.toggleFloating() }
    @objc func toggleTranslucent(_ sender: Any?) { controller?.toggleTranslucent() }
    @objc func useAsStickiesDefault(_ sender: Any?) { controller?.useAsDefault() }
    @objc func flipNote(_ sender: Any?) { controller?.flip() }
    @objc func exportText(_ sender: Any?) { controller?.exportText() }
    @objc func printDocument(_ sender: Any?) { controller?.printNote() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let result = controller?.validate(item) { return result }
        return super.validateMenuItem(item)
    }
}

final class StickyContentView: NSView {
    weak var controller: StickyController?
    /// While the flip animation runs, the window shows only the turning card.
    var isFlipping = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard !isFlipping, let controller else { return }
        (controller.showingDone ? controller.meta.color.backPaper : controller.meta.color.paper).setFill()
        dirtyRect.fill()
    }
}

/// Stickies' SNSpineView: the 12 pt bar with close (left), zoom and collapse (right).
/// Stickies+ adds one more box left of zoom: the check that flips to the done pile, or on the
/// day board a little calendar page that opens the calendar.
final class SpineView: NSView {
    enum Part: CaseIterable { case close, done, calendar, zoom, collapse }

    weak var controller: StickyController?
    private var pressed: Part?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rect(for part: Part) -> NSRect {
        let w = bounds.width
        let y = ((bounds.height - 8) / 2).rounded()   // 2 on a normal 12 pt bar
        switch part {
        case .close: return NSRect(x: 12, y: y, width: 8, height: 8)
        case .done, .calendar: return NSRect(x: w - 44, y: y, width: 8, height: 8)
        case .zoom: return NSRect(x: w - 32, y: y, width: 8, height: 8)
        case .collapse: return NSRect(x: w - 20, y: y, width: 8, height: 8)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let palette = controller.meta.color
        let active = controller.isActive
        if active || controller.meta.collapsed {
            palette.spine.setFill()
        } else {
            (controller.showingDone ? palette.backPaper : palette.paper).setFill()
        }
        bounds.fill()
        if controller.meta.collapsed { drawTitle(controller.title, active: active) }
        guard active else { return }
        for part in controller.spineParts {
            let on = (part == .done && controller.showingDone) || (part == .calendar && controller.meta.boardCalendar)
            drawButton(part, palette: palette, on: on)
        }
    }

    private func drawTitle(_ title: String, active: Bool) {
        let font = NSFont.systemFont(ofSize: 9)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let left: CGFloat = 23
        let right = bounds.width - (active ? 48 : 8)
        guard right > left else { return }
        let lineHeight = ceil(font.ascender - font.descender)
        (title as NSString).draw(
            in: NSRect(x: left, y: ((bounds.height - lineHeight) / 2).rounded(), width: right - left, height: lineHeight),
            withAttributes: [.font: font, .foregroundColor: (controller?.meta.color.text ?? .black).withAlphaComponent(0.85),
                             .paragraphStyle: style])
    }

    private func drawButton(_ part: Part, palette: StickyColor, on: Bool) {
        let box = rect(for: part).insetBy(dx: 0.5, dy: 0.5)
        let color = pressed == part ? palette.highlight : palette.control
        let path = NSBezierPath()
        path.lineWidth = 1
        switch part {
        case .close:
            path.appendRect(box)
        case .zoom:
            path.move(to: NSPoint(x: box.minX, y: box.maxY))
            path.line(to: NSPoint(x: box.maxX, y: box.minY))
            path.line(to: NSPoint(x: box.maxX, y: box.maxY))
            path.close()
        case .collapse:
            path.appendRect(box)
            path.move(to: NSPoint(x: box.minX, y: box.minY + 2))
            path.line(to: NSPoint(x: box.maxX, y: box.minY + 2))
        case .done:
            if on {
                color.setFill()
                NSBezierPath(rect: box.insetBy(dx: -0.5, dy: -0.5)).fill()
            }
            path.move(to: NSPoint(x: box.minX + 0.5, y: box.midY))
            path.line(to: NSPoint(x: box.minX + 2.5, y: box.maxY - 0.5))
            path.line(to: NSPoint(x: box.maxX - 0.5, y: box.minY + 0.5))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (on ? palette.spine : color).setStroke()
            path.stroke()
            return
        case .calendar:   // a tiny calendar page: a band along the top, two day marks
            let r = rect(for: part)
            if on {
                color.setFill()
                NSBezierPath(rect: r).fill()
            }
            path.appendRect(box)
            color.setStroke()
            path.stroke()
            (on ? palette.spine : color).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: 2.5).fill()
            NSRect(x: r.minX + 2, y: r.minY + 4.5, width: 1.5, height: 1.5).fill()
            NSRect(x: r.minX + 4.5, y: r.minY + 4.5, width: 1.5, height: 1.5).fill()
            return
        }
        color.setStroke()
        path.stroke()
        if pressed == part {
            color.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: box).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if controller.isActive, controller.hasBeenKeyBriefly,
           let part = controller.spineParts.first(where: { rect(for: $0).insetBy(dx: -2, dy: -2).contains(point) }) {
            track(part, in: window)
            return
        }
        if event.clickCount == 2 {
            controller.toggleCollapse()
            return
        }
        window.performDrag(with: event)
    }

    private func track(_ part: Part, in window: NSWindow) {
        pressed = part
        needsDisplay = true
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = rect(for: part).insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseUp {
                pressed = nil
                needsDisplay = true
                if inside { controller?.perform(part) }
                return
            }
            let now: Part? = inside ? part : nil
            if now != pressed {
                pressed = now
                needsDisplay = true
            }
        }
    }
}

/// Thin invisible strips along the edges so the borderless note can be resized from any side.
final class ResizeHandle: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    let edges: Edges
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    init(edges: Edges) {
        self.edges = edges
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        case [.bottom, .right]: position = .bottomRight
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        default: position = .right
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame ?? .zero
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
        let minSize = window.minSize, maxSize = window.maxSize
        func clampW(_ w: CGFloat) -> CGFloat { min(max(w, minSize.width), maxSize.width) }
        func clampH(_ h: CGFloat) -> CGFloat { min(max(h, minSize.height), maxSize.height) }
        var frame = startFrame
        if edges.contains(.right) { frame.size.width = clampW(startFrame.width + dx) }
        if edges.contains(.left) {
            frame.size.width = clampW(startFrame.width - dx)
            frame.origin.x = startFrame.maxX - frame.width
        }
        if edges.contains(.top) { frame.size.height = clampH(startFrame.height + dy) }
        if edges.contains(.bottom) {
            frame.size.height = clampH(startFrame.height - dy)
            frame.origin.y = startFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
    }
}
