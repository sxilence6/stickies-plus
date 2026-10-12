import AppKit
import UniformTypeIdentifiers

/// One sticky: its window, text, done pile and saved state.
final class StickyController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let spineHeight: CGFloat = 12
    /// The day board's top bar is a bit taller, so it reads as the main sticky.
    static let boardSpineHeight: CGFloat = 18
    let spineHeight: CGFloat
    static let defaultSize = NSSize(width: 300, height: 200)   // SNDocument.nib
    static let translucentAlpha: CGFloat = 0.7

    private(set) var meta: NoteMeta
    let window: StickyWindow
    private let contentView: StickyContentView
    let spine: SpineView
    private let scrollView: StickyScrollView
    let textView: ChecklistTextView
    private let donePile: DonePileView
    private var handles: [ResizeHandle] = []
    private let undo = UndoManager()
    private(set) var showingDone = false
    private(set) var title = ""
    private var saveWork: DispatchWorkItem?
    private var zoomedFrom: NSRect?
    private var keySince = Date.distantPast
    private var isDeleted = false
    private var isAnimatingFlip = false
    private var inWindowsMenu = false

    var onClose: ((StickyController) -> Void)?
    /// Something on this sticky changed that the day board may show.
    var onChange: ((StickyController) -> Void)?
    /// Set when this sticky is the day board.
    weak var board: BoardController?

    /// The day board has no done pile of its own (ticked tasks go to their own sticky's).
    var spineParts: [SpineView.Part] { meta.isBoard ? [.close, .calendar, .zoom, .collapse] : [.close, .done, .zoom, .collapse] }

    var isActive: Bool { previewActive || (window.isKeyWindow && NSApp.isActive) }
    /// Draws the top bar as if the note were active (preview images only).
    var previewActive = false
    /// Buttons only react once the note was already active, so the first click
    /// on a sleeping note can't hit an invisible close box.
    var hasBeenKeyBriefly: Bool { Date().timeIntervalSince(keySince) > 0.2 }

    init(meta: NoteMeta, text: NSAttributedString) {
        self.meta = meta
        spineHeight = meta.isBoard ? Self.boardSpineHeight : Self.spineHeight
        var frame = NSRectFromString(meta.frame)
        if frame.width < 30 || frame.height < spineHeight {
            frame = NSRect(origin: NSPoint(x: 86, y: 335), size: Self.defaultSize)
        }
        if meta.collapsed {   // build expanded, collapse after
            let height = max(meta.expandedHeight ?? Self.defaultSize.height, 30)
            frame = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        }
        window = StickyWindow(contentRect: frame)
        let bounds = NSRect(origin: .zero, size: frame.size)
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - spineHeight)
        contentView = StickyContentView(frame: bounds)
        spine = SpineView(frame: NSRect(x: 0, y: body.height, width: bounds.width, height: spineHeight))
        scrollView = StickyScrollView(frame: body)
        let (storage, container) = makeTextSystem(width: body.width)
        textView = ChecklistTextView(frame: NSRect(origin: .zero, size: body.size), textContainer: container)
        textView.ownedStorage = storage
        donePile = DonePileView(frame: body)
        super.init()
        build(text: text)
    }

    private func build(text: NSAttributedString) {
        window.controller = self
        window.delegate = self
        window.contentView = contentView
        contentView.controller = self
        contentView.wantsLayer = true
        contentView.autoresizesSubviews = true

        spine.controller = self
        spine.autoresizingMask = [.width, .minYMargin]

        scrollView.autoresizingMask = [.width, .height]
        scrollView.palette = meta.color
        donePile.palette = meta.color

        configureScrollingTextView(textView, height: scrollView.frame.height)
        if meta.isBoard { textView.textContainerInset = NSSize(width: 10, height: 6) }   // room for the stickies' color bars
        textView.palette = meta.color
        textView.doneDelay = AppSettings.doneDelay
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesFindPanel = true
        textView.usesRuler = false
        textView.insertionPointColor = .black
        textView.isContinuousSpellCheckingEnabled = true
        textView.delegate = self
        textView.textStorage?.delegate = textView
        textView.textStorage?.setAttributedString(text)
        textView.applyMarks(meta.checklist)
        if !meta.fontsRepaired, !meta.isBoard {
            meta.fontsRepaired = true
            if textView.repairLeakedDateFont(defaultSize: AppSettings.defaultFont.pointSize) { scheduleSave() }
        }
        if !meta.isBoard, textView.sortTasksByDate(undoable: false) { scheduleSave() }
        if text.length == 0 { textView.typingAttributes = AppSettings.defaultTypingAttributes }
        scrollView.documentView = textView

        donePile.autoresizingMask = [.width, .height]
        donePile.isHidden = true
        donePile.controller = self

        contentView.addSubview(scrollView)
        contentView.addSubview(donePile)
        contentView.addSubview(spine)
        addResizeHandles()

        window.initialFirstResponder = textView
        window.level = meta.floating ? .floating : .normal
        window.alphaValue = meta.translucent ? Self.translucentAlpha : 1
        if meta.collapsed {
            applyCollapsedLayout(true)
            let f = window.frame
            window.setFrame(NSRect(x: f.minX, y: f.maxY - spineHeight, width: f.width, height: spineHeight), display: false)
        }
        updateTitle()
    }

    private func addResizeHandles() {
        let b = contentView.bounds
        let t: CGFloat = 4, c: CGFloat = 8
        let specs: [(ResizeHandle.Edges, NSRect, NSView.AutoresizingMask)] = [
            (.left, NSRect(x: 0, y: c, width: t, height: b.height - 2 * c), [.height, .maxXMargin]),
            (.right, NSRect(x: b.width - t, y: c, width: t, height: b.height - 2 * c), [.height, .minXMargin]),
            (.bottom, NSRect(x: c, y: 0, width: b.width - 2 * c, height: t), [.width, .maxYMargin]),
            (.top, NSRect(x: c, y: b.height - 2, width: b.width - 2 * c, height: 2), [.width, .minYMargin]),
            ([.bottom, .left], NSRect(x: 0, y: 0, width: c, height: c), [.maxXMargin, .maxYMargin]),
            ([.bottom, .right], NSRect(x: b.width - c, y: 0, width: c, height: c), [.minXMargin, .maxYMargin]),
            ([.top, .left], NSRect(x: 0, y: b.height - 2, width: c, height: 2), [.maxXMargin, .minYMargin]),
            ([.top, .right], NSRect(x: b.width - c, y: b.height - 2, width: c, height: 2), [.minXMargin, .minYMargin]),
        ]
        for (edges, frame, mask) in specs {
            let handle = ResizeHandle(edges: edges)
            handle.frame = frame
            handle.autoresizingMask = mask
            contentView.addSubview(handle)
            handles.append(handle)
        }
    }

    // MARK: Spine buttons

    func perform(_ part: SpineView.Part) {
        switch part {
        case .close: closeNote()
        case .done: if !meta.isBoard { flip() }
        case .calendar: board?.toggleCalendar()
        case .zoom: zoom()
        case .collapse: toggleCollapse()
        }
    }

    // MARK: Collapse / zoom

    func toggleCollapse() { setCollapsed(!meta.collapsed, animate: true) }

    func setCollapsed(_ collapsed: Bool, animate: Bool) {
        guard collapsed != meta.collapsed else { return }
        var frame = window.frame
        if collapsed {
            meta.expandedHeight = frame.height
            frame.origin.y = frame.maxY - spineHeight
            frame.size.height = spineHeight
        } else {
            let height = max(meta.expandedHeight ?? Self.defaultSize.height, 30)
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            meta.expandedHeight = nil
        }
        meta.collapsed = collapsed
        zoomedFrom = nil
        if collapsed {
            applyCollapsedLayout(true)
            window.setFrame(frame, display: true, animate: animate)
        } else {
            window.setFrame(frame, display: true, animate: animate)
            applyCollapsedLayout(false)
        }
        scheduleSave()
    }

    private func applyCollapsedLayout(_ collapsed: Bool) {
        window.minSize = NSSize(width: 30, height: collapsed ? spineHeight : 30)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: collapsed ? spineHeight : CGFloat.greatestFiniteMagnitude)
        if collapsed {
            window.makeFirstResponder(nil)
        } else {
            window.makeFirstResponder(showingDone ? donePile.textView : textView)
        }
        scrollView.isHidden = collapsed || showingDone
        donePile.isHidden = collapsed || !showingDone
        handles.forEach { $0.isHidden = collapsed }
        spine.needsDisplay = true
    }

    /// Stickies' zoom: grow or shrink the note to fit its text; again to go back.
    func zoom() {
        if meta.collapsed { setCollapsed(false, animate: true); return }
        if let previous = zoomedFrom {
            zoomedFrom = nil
            window.setFrame(previous, display: true, animate: true)
            return
        }
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let needed = layout.usedRect(for: container).height + textView.textContainerInset.height * 2 + spineHeight + 2
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var frame = window.frame
        let height = min(max(needed, 30), frame.maxY - visible.minY)
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        zoomedFrom = window.frame
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Note actions

    func closeNote() {
        if meta.isBoard {   // the board only hides; Window › Day Board brings it back
            window.orderOut(nil)
            return
        }
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText || !meta.done.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Delete this note?"
            alert.informativeText = meta.done.isEmpty
                ? "It goes to the Trash, so you can still get it back."
                : "It goes to the Trash together with its done pile (\(meta.done.count) finished)."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isDeleted = true
        saveWork?.cancel()
        NoteStore.trash(meta.id)
        window.orderOut(nil)
        NSApp.removeWindowsItem(window)
        onClose?(self)
    }

    func setColor(_ color: StickyColor) {
        meta.color = color
        textView.palette = color
        scrollView.palette = color
        donePile.palette = color
        contentView.needsDisplay = true
        spine.needsDisplay = true
        if showingDone { reloadDonePile() }
        scheduleSave()
    }

    func toggleFloating() {
        meta.floating.toggle()
        window.level = meta.floating ? .floating : .normal
        scheduleSave()
    }

    func toggleTranslucent() {
        meta.translucent.toggle()
        window.alphaValue = meta.translucent ? Self.translucentAlpha : 1
        scheduleSave()
    }

    func useAsDefault() {
        AppSettings.defaultColor = meta.color
        if let font = textView.typingAttributes[.font] as? NSFont { AppSettings.defaultFont = font }
    }

    func printNote() {
        NSPrintOperation(view: textView).run()
    }

    func exportText() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.isEmpty ? "Note" : title.replacingOccurrences(of: "/", with: "-")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Plain Text", "RTF", "RTFD"])
        let hasAttachments = textView.textStorage?.containsAttachments ?? false
        popup.selectItem(at: hasAttachments ? 2 : 1)
        let types: [UTType] = [.plainText, .rtf, .rtfd]
        let switcher = PopupAction { panel.allowedContentTypes = [types[popup.indexOfSelectedItem]] }
        popup.target = switcher
        popup.action = #selector(PopupAction.fire(_:))
        switcher.fire(nil)
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        panel.accessoryView = row
        guard panel.runModal() == .OK, let url = panel.url, let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        do {
            switch popup.indexOfSelectedItem {
            case 0:
                try storage.string.write(to: url, atomically: true, encoding: .utf8)
            case 1:
                try storage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
            default:
                try storage.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                    .write(to: url, options: .atomic, originalContentsURL: nil)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        _ = switcher
    }

    // MARK: Done pile

    func flip() { setShowingDone(!showingDone, animated: true) }

    func setShowingDone(_ show: Bool, animated: Bool) {
        guard show != showingDone, !isAnimatingFlip else { return }
        if meta.collapsed { setCollapsed(false, animate: false) }
        if show { reloadDonePile() }
        let swap = { [self] in
            showingDone = show
            scrollView.isHidden = show
            donePile.isHidden = !show
            window.makeFirstResponder(show ? donePile.textView : textView)
            spine.needsDisplay = true
            contentView.needsDisplay = true
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = contentView.layer, let before = contentView.snapshot() else {
            swap()
            return
        }
        swap()
        contentView.layoutSubtreeIfNeeded()
        guard let after = contentView.snapshot() else { return }
        runFlip(from: before, to: after, on: layer)
    }

    /// The whole note turns over like a card.
    private func runFlip(from before: NSImage, to after: NSImage, on root: CALayer) {
        isAnimatingFlip = true
        let scale = window.backingScaleFactor
        let stage = CALayer()
        stage.frame = root.bounds
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 900
        stage.sublayerTransform = perspective
        let card = CALayer()
        card.frame = stage.bounds
        card.contentsGravity = .resize
        card.contentsScale = scale
        card.contents = before
        stage.addSublayer(card)

        let parts: [NSView] = contentView.subviews.filter { !$0.isHidden }
        parts.forEach { $0.isHidden = true }
        contentView.isFlipping = true
        contentView.displayIfNeeded()
        window.hasShadow = false
        root.addSublayer(stage)

        let half = 0.14
        CATransaction.begin()
        CATransaction.setAnimationDuration(half)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.contents = after
            card.transform = CATransform3DMakeRotation(-.pi / 2, 0, 1, 0)
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(half)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock {
                stage.removeFromSuperlayer()
                guard let self else { return }
                parts.forEach { $0.isHidden = false }
                self.scrollView.isHidden = self.showingDone || self.meta.collapsed
                self.donePile.isHidden = !self.showingDone || self.meta.collapsed
                self.contentView.isFlipping = false
                self.window.hasShadow = true
                self.window.invalidateShadow()
                self.isAnimatingFlip = false
            }
            card.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        card.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
        CATransaction.commit()
    }

    func reloadDonePile() {
        donePile.reload(items: meta.done, title: title, palette: meta.color, delay: AppSettings.doneDelay)
    }

    func putBack(_ index: Int) {
        guard meta.done.indices.contains(index) else { return }
        let item = meta.done.remove(at: index)
        textView.appendChecklistLine(item.text, font: AppSettings.defaultFont)
        reloadDonePile()
        updateTitle()
        saveNow()
        onChange?(self)
    }

    func removeDone(_ index: Int) {
        guard meta.done.indices.contains(index) else { return }
        meta.done.remove(at: index)
        reloadDonePile()
        saveNow()
    }

    func clearDone() {
        let alert = NSAlert()
        alert.messageText = "Clear this note's done pile?"
        alert.informativeText = "\(meta.done.count) finished \(meta.done.count == 1 ? "task" : "tasks") will be removed. This can't be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        meta.done.removeAll()
        reloadDonePile()
        saveNow()
    }

    /// Called by the app timer: move lines ticked 13+ hours ago to the done pile, refresh the fading.
    func tick(now: Date = Date()) {
        if meta.isBoard {
            textView.needsDisplay = true
            return
        }
        textView.doneDelay = AppSettings.doneDelay
        let items = textView.removeExpiredItems(now: now.timeIntervalSinceReferenceDate)
        if !items.isEmpty {
            meta.done.append(contentsOf: items)
            meta.done.sort { $0.finishedAt > $1.finishedAt }
            meta.modified = now
            updateTitle()
            if showingDone { reloadDonePile() }
            saveNow()
            onChange?(self)
        }
        textView.refreshCheckedAppearance()
    }

    func setBoardOpen(_ open: [String]) {
        meta.boardOpen = open
        scheduleSave()
    }

    /// For the day board's own settings (folded groups, calendar).
    func updateBoardSettings(_ change: (inout NoteMeta) -> Void) {
        change(&meta)
        scheduleSave()
    }

    // MARK: Menu validation

    func validate(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(StickyWindow.clickColorMenuItem(_:))?:
            item.state = StickyColor.allCases.indices.contains(item.tag) && StickyColor.allCases[item.tag] == meta.color ? .on : .off
            return true
        case #selector(StickyWindow.toggleFloatingMenuAction(_:))?:
            item.state = meta.floating ? .on : .off
            return true
        case #selector(StickyWindow.toggleTranslucent(_:))?:
            item.state = meta.translucent ? .on : .off
            return true
        case #selector(StickyWindow.performCollapse(_:))?:
            item.title = meta.collapsed ? "Expand" : "Collapse"
            return true
        case #selector(StickyWindow.flipNote(_:))?:
            item.title = showingDone ? "Show Note" : "Show Done Pile"
            return !meta.isBoard
        case #selector(NSWindow.performClose(_:))?, #selector(NSWindow.performZoom(_:))?,
             #selector(NSWindow.performMiniaturize(_:))?, #selector(StickyWindow.useAsStickiesDefault(_:))?,
             #selector(StickyWindow.exportText(_:))?, #selector(StickyWindow.printDocument(_:))?:
            return true
        default:
            return nil
        }
    }

    // MARK: Title & saving

    func updateTitle() {
        let s = (textView.textStorage?.string ?? "") as NSString
        var first = ""
        for p in s.paragraphRanges(in: NSRange(location: 0, length: s.length)) {
            let line = s.substring(with: p).replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { first = line; break }
        }
        title = meta.isBoard ? "Today" : String(first.prefix(40))
        let windowTitle = title.isEmpty ? "Untitled…" : title + "…"   // Stickies style
        if window.title != windowTitle {
            window.title = windowTitle
            if inWindowsMenu {
                NSApp.changeWindowsItem(window, title: windowTitle, filename: false)
            } else {
                // Borderless windows aren't listed automatically; Stickies lists every note.
                NSApp.addWindowsItem(window, title: windowTitle, filename: false)
                inWindowsMenu = true
            }
        }
        if meta.collapsed { spine.needsDisplay = true }
    }

    func setOrder(_ order: Int) { meta.order = order }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard !isDeleted, let storage = textView.textStorage else { return }
        meta.frame = NSStringFromRect(window.frame)
        meta.checklist = meta.isBoard ? [] : textView.checklistMarks()
        do {   // the board's text is rebuilt from the other stickies, so only its window is saved
            try NoteStore.save(meta, text: meta.isBoard ? NSAttributedString() : NSAttributedString(attributedString: storage))
        } catch {
            NSLog("Stickies+: could not save note \(meta.id): \(error)")
        }
    }

    // MARK: Delegates

    func textDidChange(_ notification: Notification) {
        if meta.isBoard {
            board?.boardTextDidChange()
            return
        }
        meta.modified = Date()
        updateTitle()
        scheduleSave()
        onChange?(self)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    func windowDidMove(_ notification: Notification) { scheduleSave() }

    func windowDidResize(_ notification: Notification) {
        scheduleSave()
        textView.queueAppearanceRefresh()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        keySince = Date()
        spine.needsDisplay = true
    }

    func windowDidResignKey(_ notification: Notification) {
        spine.needsDisplay = true
        textView.commitAll()
        board?.didResignKey()
    }
}

/// Target/action bridge for a closure (NSPopUpButton in the export panel).
private final class PopupAction: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire(_ sender: Any?) { body() }
}

extension NSView {
    func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
