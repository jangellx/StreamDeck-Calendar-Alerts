import Foundation
import AppKit
import EventKit

// Runs as an independent .app process (CalendarHelper.app) launched via NSWorkspace.
// Reads calendar events via EventKit (with its own TCC context) and writes them to
// shared temp files that the plugin binary reads.
final class CalendarServiceRunner {
    private let store = EKEventStore()

    func start() {
        let status = EKEventStore.authorizationStatus(for: .event)
        NSLog("[CalendarHelper] EKAuthorizationStatus raw=\(status.rawValue)")

        switch status {
        case .fullAccess, .authorized:
            beginWritingEvents()
        case .notDetermined:
            NSApp.setActivationPolicy(.regular)
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        NSApp.setActivationPolicy(.accessory)
                        self?.beginWritingEvents()
                    } else {
                        NSLog("[CalendarHelper] Permission denied — exiting")
                        NSApp.terminate(nil)
                    }
                }
            }
        default:
            NSLog("[CalendarHelper] Calendar access denied/restricted — exiting")
            NSApp.terminate(nil)
        }
    }

    private func beginWritingEvents() {
        NSLog("[CalendarHelper] Starting event writer")
        writeSharedFiles()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.writeSharedFiles()
        }
    }

    private func writeSharedFiles() {
        writeEventsFile()
        writeCalendarsFile()
    }

    private func writeEventsFile() {
        let now = Date()
        let cal = Calendar.current
        guard let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return }

        let pred = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: pred)
            .filter { $0.startDate > now && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { event -> [String: Any] in
                [
                    "title": event.title ?? "",
                    "startDate": event.startDate.timeIntervalSince1970,
                    "endDate": event.endDate.timeIntervalSince1970,
                    "identifier": event.eventIdentifier ?? "",
                    "calendarIdentifier": event.calendar?.calendarIdentifier ?? ""
                ]
            }

        if let data = try? JSONSerialization.data(withJSONObject: events) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/calendar-alerts-events.json"))
        }
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
        if let data = try? JSONSerialization.data(withJSONObject: calendars) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/calendar-alerts-calendars.json"))
        }
    }
}
