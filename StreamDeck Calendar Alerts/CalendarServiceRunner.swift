import Foundation
import AppKit
import EventKit

// Runs as an independent .app process (CalendarHelper.app) launched via NSWorkspace.
// Reads calendar events via EventKit (with its own TCC context) and writes them to
// the shared files in CalendarManager that the plugin binary reads.
final class CalendarServiceRunner {
    private var store = EKEventStore()
    private var refreshTimer: Timer?
    private var accessPollTimer: Timer?
    private var storeObserver: NSObjectProtocol?
    private var parentWatch: DispatchSourceProcess?

    // Exit when the plugin process that launched us exits, so a helper never
    // outlives Stream Deck or keeps running old code after a deploy.
    func watchParent(pid: pid_t) {
        guard kill(pid, 0) == 0 else {
            NSLog("[CalendarHelper] Plugin process \(pid) is already gone — exiting")
            exit(0)
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            NSLog("[CalendarHelper] Plugin process \(pid) exited — exiting")
            exit(0)
        }
        source.resume()
        parentWatch = source
    }

    func start() {
        removeLegacyFiles()

        let status = EKEventStore.authorizationStatus(for: .event)
        NSLog("[CalendarHelper] EKAuthorizationStatus raw=\(status.rawValue)")

        switch status {
        case .fullAccess:
            beginWritingEvents()
        case .notDetermined:
            // Become a regular app so the permission prompt can come to the front.
            NSApp.setActivationPolicy(.regular)
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                    if granted {
                        self?.beginWritingEvents()
                    } else {
                        self?.handleAccessDenied()
                    }
                }
            }
        default:
            handleAccessDenied()
        }
    }

    // Tell the plugin access is missing, so the key and the settings panel can say
    // so, then keep checking: access can be granted later in System Settings.
    private func handleAccessDenied() {
        NSLog("[CalendarHelper] Calendar access denied/restricted — waiting for it to be granted")
        CalendarManager.writeJSON(["authorized": false], to: CalendarManager.statusURL)
        CalendarManager.writeJSON([], to: CalendarManager.eventsURL)
        CalendarManager.writeJSON([], to: CalendarManager.calendarsURL)

        accessPollTimer?.invalidate()
        accessPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            guard let self, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
            timer.invalidate()
            self.accessPollTimer = nil
            // A store created before access was granted can stay empty; start fresh.
            self.store = EKEventStore()
            self.beginWritingEvents()
        }
    }

    private func beginWritingEvents() {
        NSLog("[CalendarHelper] Starting event writer")
        CalendarManager.writeJSON(["authorized": true], to: CalendarManager.statusURL)
        writeSharedFiles()

        // Rewrite as soon as a calendar changes, with a periodic refresh as a backstop.
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            self?.writeSharedFiles()
        }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.writeSharedFiles()
        }
    }

    private func writeSharedFiles() {
        writeEventsFile()
        writeCalendarsFile()
    }

    private func writeEventsFile() {
        let now = Date()
        guard let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return }

        let pred = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: pred)
            .filter { $0.startDate > now && !$0.isAllDay && !Self.isCanceledOrDeclined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { event -> [String: Any] in
                [
                    "title": event.title ?? "",
                    "startDate": event.startDate.timeIntervalSince1970,
                    "endDate": event.endDate.timeIntervalSince1970,
                    "identifier": event.eventIdentifier ?? "",
                    "calendarIdentifier": event.calendar?.calendarIdentifier ?? "",
                    // Used to open the event in other apps when the key is pressed.
                    "calendarItemIdentifier": event.calendarItemIdentifier,
                    "externalIdentifier": event.calendarItemExternalIdentifier ?? "",
                    "calendarTitle": event.calendar?.title ?? "",
                    "accountEmail": Self.accountEmail(for: event.calendar) ?? ""
                ]
            }
        CalendarManager.writeJSON(events, to: CalendarManager.eventsURL)
    }

    // The email address of the account a calendar belongs to, when macOS exposes
    // it. EventKit has no property for this; the source's description includes
    // "mailto:<address>" for Google and Exchange accounts (the approach MeetingBar
    // uses), and some accounts are simply titled with the address.
    private static func accountEmail(for calendar: EKCalendar?) -> String? {
        guard let source = calendar?.source else { return nil }
        let description = source.description
        if let regex = try? NSRegularExpression(pattern: #""mailto:([^"@]+@[^"]+)""#),
           let match = regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)),
           let range = Range(match.range(at: 1), in: description) {
            return String(description[range])
        }
        return source.title.contains("@") ? source.title : nil
    }

    // Meetings that were cancelled, or that you declined, shouldn't raise alerts.
    private static func isCanceledOrDeclined(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return true }
        if let me = event.attendees?.first(where: { $0.isCurrentUser }),
           me.participantStatus == .declined {
            return true
        }
        return false
    }

    private func writeCalendarsFile() {
        let calendars = store.calendars(for: .event).map { cal -> [String: Any] in
            var hex = "#888888"
            if let rgb = cal.color.usingColorSpace(.sRGB) {
                let r = Int((rgb.redComponent * 255).rounded())
                let g = Int((rgb.greenComponent * 255).rounded())
                let b = Int((rgb.blueComponent * 255).rounded())
                hex = String(format: "#%02X%02X%02X", r, g, b)
            }
            return ["id": cal.calendarIdentifier, "title": cal.title, "color": hex]
        }
        CalendarManager.writeJSON(calendars, to: CalendarManager.calendarsURL)
    }

    // Earlier versions wrote world-readable copies of the shared files to /tmp.
    private func removeLegacyFiles() {
        for name in ["calendar-alerts-events.json", "calendar-alerts-calendars.json"] {
            try? FileManager.default.removeItem(atPath: "/tmp/" + name)
        }
    }
}
