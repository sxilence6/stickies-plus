import AppKit
import EventKit
import ServiceManagement

/// Today's and tomorrow's events from Apple Calendar (which includes Google accounts
/// added to it). Read-only: nothing in your calendar is ever changed.
final class CalendarEvents: BoardEventSource {
    private let store = EKEventStore()
    private var authorized = false
    var onChange: (() -> Void)?
    var calendar = Calendar.current

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.onChange?()
        }
    }

    /// Asks once (macOS shows its own permission dialog), then remembers.
    func requestAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorized = true
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.authorized = granted
                    self?.onChange?()
                }
            }
        default:
            authorized = false
        }
    }

    func events(on day: Date) -> [BoardEvent] {
        guard authorized, let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        let predicate = store.predicateForEvents(withStart: day, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            BoardEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay)
        }
    }
}

/// The small count in the menu bar: tasks left today, red when something is late.
final class StatusCount: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onClick: (() -> Void)?

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Stickies+ today")
        item.button?.imagePosition = .imageLeading
        update(open: 0, late: 0)
    }

    func update(open: Int, late: Int) {
        let color: NSColor = late > 0 ? .systemRed : .labelColor
        item.button?.attributedTitle = NSAttributedString(
            string: open > 0 ? " \(open)" : "",
            attributes: [.foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
        item.button?.contentTintColor = late > 0 ? .systemRed : nil
        item.button?.toolTip = open == 0 ? "Nothing left today" : "\(open) left today" + (late > 0 ? ", \(late) late" : "")
    }

    @objc private func clicked(_ sender: Any?) { onClick?() }
}

/// Open at login, through macOS's own login items (System Settings › General › Login Items).
enum LoginItem {
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "OpenAtLogin") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "OpenAtLogin")
            apply()
        }
    }

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Test copies (started with -DataDir) never touch login items. If the app was moved (say from
    /// the build folder into Applications), it registers again so login opens this copy.
    static func apply() {
        guard UserDefaults.standard.string(forKey: "DataDir") == nil else { return }
        let here = Bundle.main.bundlePath
        let moved = UserDefaults.standard.string(forKey: "LoginItemPath") != here
        do {
            if wanted, moved || SMAppService.mainApp.status != .enabled {
                if moved { try? SMAppService.mainApp.unregister() }
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(here, forKey: "LoginItemPath")
            } else if !wanted, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Stickies+: login item: \(error)")
        }
    }
}
