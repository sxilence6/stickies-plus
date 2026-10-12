import AppKit
import UniformTypeIdentifiers

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    override public init() {
        // Stickies sets this too: no "Enter Full Screen" in the Window menu.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        super.init()
    }
    private var controllers: [StickyController] = []   // every sticky, the day board included
    private var timer: Timer?
    private var board: BoardController?
    private var statusCount: StatusCount?
    private let calendarEvents = CalendarEvents()
    private var isTestCopy: Bool { UserDefaults.standard.string(forKey: "DataDir") != nil }

    private struct Placement {
        var frame: NSRect
        var collapsed: Bool
        var expandedHeight: CGFloat?
    }
    private var arrangeUndo: [[UUID: Placement]] = []
    private var arrangeRedo: [[UUID: Placement]] = []

    // MARK: Launch & quit

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        var notes = NoteStore.loadAll()
        if !UserDefaults.standard.bool(forKey: "ImportedAppleStickies"), let imported = NoteStore.readAppleStickies() {
            UserDefaults.standard.set(true, forKey: "ImportedAppleStickies")
            notes += save(imported, skipping: Set(notes.map { $0.0.id }))
        }
        // order 0 = frontmost, so bring the back ones forward first.
        for (meta, text) in notes.sorted(by: { $0.0.order > $1.0.order }) {
            let controller = add(StickyController(meta: meta, text: text))
            controller.window.orderFront(nil)
        }
        if !controllers.contains(where: { $0.meta.isBoard }) { createBoard() }
        if controllers.allSatisfy(\.meta.isBoard) { newNote() }
        if let boardSticky = controllers.first(where: { $0.meta.isBoard }) { setUpBoard(boardSticky) }
        controllers.last?.window.makeKeyAndOrderFront(nil)

        LoginItem.apply()
        startTimer()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSApp.activate()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ChecklistTextView.commitAllPending()
        controllers.forEach { $0.textView.commitAll() }
        board?.fileUnfiledLines()
        saveAll()
        return .terminateNow
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty {
            newNote()
        } else if !flag {
            controllers.forEach { $0.window.orderFront(nil) }
        }
        return true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        controllers.forEach { $0.spine.needsDisplay = true }
    }

    public func applicationDidResignActive(_ notification: Notification) {
        controllers.forEach { $0.spine.needsDisplay = true }
        saveAll()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func saveAll() {
        let ordered = NSApp.orderedWindows
        for controller in controllers {
            controller.setOrder(ordered.firstIndex(of: controller.window) ?? ordered.count)
            controller.saveNow()
        }
    }

    // MARK: The 13-hour clock

    private func startTimer() {
        // Every 30 s is plenty for 13 hours; short test delays tick faster.
        let interval = min(30, max(1, AppSettings.doneDelay / 10))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAll() }
        }
        timer?.tolerance = interval / 5
        tickAll()
    }

    private func tickAll() {
        let now = Date()
        controllers.forEach { $0.tick(now: now) }
        board?.requestRebuild()   // times move tasks between sections and toward red
        morningEntrance(now: now)
    }

    /// Once a day, at 8:00 (or the first time the Mac is awake after 8:00), the board comes to the
    /// front. It doesn't take the keyboard from whatever you're doing.
    private func morningEntrance(now: Date) {
        guard !isTestCopy, let sticky = board?.sticky else { return }
        let cal = Calendar.current
        guard let eight = cal.date(bySettingHour: 8, minute: 0, second: 0, of: now), now >= eight else { return }
        if let last = UserDefaults.standard.object(forKey: "MorningShown") as? Date, cal.isDate(last, inSameDayAs: now) { return }
        UserDefaults.standard.set(now, forKey: "MorningShown")
        if sticky.meta.collapsed { sticky.setCollapsed(false, animate: false) }
        sticky.window.orderFrontRegardless()
        board?.rebuild()
    }

    @objc private func systemDidWake(_ notification: Notification) { tickAll() }

    // MARK: Notes

    @discardableResult
    private func add(_ controller: StickyController) -> StickyController {
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.board?.requestRebuild()
        }
        controller.onChange = { [weak self] _ in self?.board?.requestRebuild() }
        controllers.append(controller)
        return controller
    }

    // MARK: Day board

    private func createBoard() {
        var meta = NoteMeta()
        meta.isBoard = true
        meta.color = AppSettings.defaultColor
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        meta.frame = NSStringFromRect(NSRect(x: screen.maxX - 324, y: screen.maxY - 404, width: 300, height: 380))
        let sticky = add(StickyController(meta: meta, text: NSAttributedString()))
        sticky.window.orderFront(nil)
        sticky.saveNow()
    }

    private func setUpBoard(_ sticky: StickyController) {
        let board = BoardController(sticky: sticky)
        board.notes = { [weak self] in self?.controllers ?? [] }
        board.createNote = { [weak self] title in
            guard let self else { return nil }
            let note = self.newNote(text: NSAttributedString(string: title, attributes: AppSettings.defaultTypingAttributes))
            sticky.window.orderFront(nil)
            return note
        }
        let status = StatusCount()
        status.onClick = { [weak self] in self?.showDayBoard(nil) }
        board.onCounts = { [weak status] open, late in status?.update(open: open, late: late) }
        statusCount = status
        if !isTestCopy {
            calendarEvents.requestAccess()
            board.events = calendarEvents
        }
        self.board = board
        board.rebuild()
    }

    @objc func showDayBoard(_ sender: Any?) {
        guard let sticky = board?.sticky else { return }
        NSApp.activate()
        if sticky.meta.collapsed { sticky.setCollapsed(false, animate: false) }
        sticky.window.makeKeyAndOrderFront(nil)
        board?.rebuild()
    }

    @objc func toggleDayCalendar(_ sender: Any?) {
        showDayBoard(nil)
        board?.toggleCalendar()
    }

    @objc func toggleOpenAtLogin(_ sender: Any?) {
        LoginItem.wanted.toggle()
    }

    @discardableResult
    private func newNote(text: NSAttributedString = NSAttributedString()) -> StickyController {
        var meta = NoteMeta()
        meta.color = AppSettings.defaultColor
        meta.frame = NSStringFromRect(nextFrame())
        let controller = add(StickyController(meta: meta, text: text))
        controller.window.makeKeyAndOrderFront(nil)
        controller.saveNow()
        return controller
    }

    private func nextFrame() -> NSRect {
        let size = StickyController.defaultSize
        if let key = NSApp.keyWindow as? StickyWindow {
            return NSRect(x: key.frame.minX + 22, y: key.frame.maxY - 22 - size.height, width: size.width, height: size.height)
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.minX + 86, y: screen.maxY - 80 - size.height, width: size.width, height: size.height)
    }

    private func save(_ notes: [(NoteMeta, NSAttributedString)], skipping existing: Set<UUID>) -> [(NoteMeta, NSAttributedString)] {
        var added: [(NoteMeta, NSAttributedString)] = []
        for (meta, text) in notes where !existing.contains(meta.id) {
            do {
                try NoteStore.save(meta, text: text)
                added.append((meta, text))
            } catch {
                NSLog("Stickies+: could not import note \(meta.id): \(error)")
            }
        }
        return added
    }

    @objc func newDocument(_ sender: Any?) { newNote() }

    @objc func importText(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd, .text]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                newNote(text: try NSAttributedString(url: url, options: [:], documentAttributes: nil))
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func importAppleStickies(_ sender: Any?) {
        guard let notes = NoteStore.readAppleStickies() else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t read your Stickies notes."
            alert.informativeText = "If macOS asked whether Stickies+ may access data from other apps, allow it and try again. You can also change this in System Settings › Privacy & Security."
            alert.runModal()
            return
        }
        UserDefaults.standard.set(true, forKey: "ImportedAppleStickies")
        let added = save(notes, skipping: Set(controllers.map { $0.meta.id }))
        for (meta, text) in added { add(StickyController(meta: meta, text: text)).window.orderFront(nil) }
        let alert = NSAlert()
        alert.messageText = added.isEmpty ? "All your Stickies notes are already here." : "Imported \(added.count) \(added.count == 1 ? "note" : "notes") from Stickies."
        alert.informativeText = "Stickies itself wasn’t changed."
        alert.runModal()
    }

    // MARK: Window menu

    @objc func performCollapseAll(_ sender: Any?) {
        let collapse = controllers.contains { !$0.meta.collapsed }
        controllers.forEach { $0.setCollapsed(collapse, animate: true) }
    }

    @objc func chooseCollapseWhenArranging(_ sender: NSMenuItem) {
        AppSettings.collapseWhenArranging = sender.tag
    }

    /// Stacks the notes in the top-left corner, every spine visible.
    @objc func arrange(_ sender: NSMenuItem) {
        guard !controllers.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let order = StickyColor.allCases
        let sorted: [StickyController]
        switch sender.tag {
        case 0: sorted = controllers.sorted { order.firstIndex(of: $0.meta.color)! < order.firstIndex(of: $1.meta.color)! }
        case 1: sorted = controllers.sorted { $0.textView.string.localizedCaseInsensitiveCompare($1.textView.string) == .orderedAscending }
        case 2: sorted = controllers.sorted { $0.meta.created < $1.meta.created }
        default: sorted = controllers.sorted { ($0.window.frame.maxY, -$0.window.frame.minX) > ($1.window.frame.maxY, -$1.window.frame.minX) }
        }
        arrangeUndo.append(placements())
        arrangeRedo.removeAll()
        let mode = AppSettings.collapseWhenArranging
        for (index, controller) in sorted.enumerated() {
            if mode == 1 { controller.setCollapsed(true, animate: false) }
            if mode == 2 { controller.setCollapsed(false, animate: false) }
            var frame = controller.window.frame
            let top = screen.maxY - 4 - CGFloat(index) * (StickyController.spineHeight + 4)
            frame.origin = NSPoint(x: screen.minX + 4, y: top - frame.height)
            controller.window.setFrame(frame, display: true)
            controller.window.orderFront(nil)
        }
    }

    @objc func undoArrange(_ sender: Any?) {
        guard let previous = arrangeUndo.popLast() else { return }
        arrangeRedo.append(placements())
        apply(previous)
    }

    @objc func redoArrange(_ sender: Any?) {
        guard let next = arrangeRedo.popLast() else { return }
        arrangeUndo.append(placements())
        apply(next)
    }

    private func placements() -> [UUID: Placement] {
        Dictionary(uniqueKeysWithValues: controllers.map {
            ($0.meta.id, Placement(frame: $0.window.frame, collapsed: $0.meta.collapsed, expandedHeight: $0.meta.expandedHeight))
        })
    }

    private func apply(_ placements: [UUID: Placement]) {
        for controller in controllers {
            guard let placement = placements[controller.meta.id] else { continue }
            controller.setCollapsed(placement.collapsed, animate: false)
            controller.window.setFrame(placement.frame, display: true)
            controller.scheduleSave()
        }
    }

    // MARK: Help

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Stickies+"
        alert.informativeText = """
        Works like Stickies, plus checklists and a day board.

        ⇧⌘L  checkboxes · Tab / ⇧Tab  subtasks · ▸ folds what's under a line
        Click a box to tick it. Ticked lines fade and after \(DonePileView.describe(AppSettings.doneDelay)) go to that sticky's done pile (⇧⌘D).

        Dates: write them at the end of a task — today, tomorrow, fri, next week, 16 oct, 16.10., 15:00, zítra, pátek. When you leave the line it becomes a fixed date like "Fri 16 Oct". Repeating: every day, every mon, každý den.
        Tasks warm up to red in the last 6 hours (your day ends at 2:00) and late ones sit red at the top of Today.

        ⇧⌘B  Day Board: the date, a punch card of today, late tasks, events, then each sticky's tasks as a group (click a sticky's name to fold it). Tomorrow, This week and Later are in the line at the bottom. Click the date for a three-week calendar; click a day to list it. Edit or tick there and it changes in the task's own sticky. Type a new task there and it goes to your random pile, or to a sticky with #name.
        Dated tasks sort themselves inside each block of a sticky.
        """
        alert.runModal()
    }

    // MARK: Validation

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleDayCalendar(_:)) {
            item.title = board?.sticky.meta.boardCalendar == true ? "Hide Calendar" : "Show Calendar"
            return board != nil
        }
        if item.action == #selector(toggleOpenAtLogin(_:)) {
            item.state = LoginItem.wanted ? .on : .off
            return !isTestCopy
        }
        if item.action == #selector(undoArrange(_:)) { return !arrangeUndo.isEmpty }
        if item.action == #selector(redoArrange(_:)) { return !arrangeRedo.isEmpty }
        if item.action == #selector(chooseCollapseWhenArranging(_:)) {
            item.state = item.tag == AppSettings.collapseWhenArranging ? .on : .off
            return true
        }
        if item.action == #selector(arrange(_:)) || item.action == #selector(performCollapseAll(_:)) {
            return !controllers.isEmpty
        }
        return true
    }
}
