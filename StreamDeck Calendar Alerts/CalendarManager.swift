import Foundation
import AppKit
import EventKit

struct CalendarInfo {
    let id: String
    let title: String
    let hexColor: String
}

struct SharedEvent {
    let title: String
    let startDate: Date
    let endDate: Date
    let identifier: String
    let calendarIdentifier: String
}

// CalendarManager is used by CalendarServiceRunner (running in CalendarHelper.app)
// to access EventKit. The plugin binary itself reads from shared temp files instead.
final class CalendarManager {
    static let shared = CalendarManager()
    private let store = EKEventStore()
    private(set) var isAuthorized = false

    private init() {}

    func requestAccess(completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        NSLog("[CalendarAlerts] EKAuthorizationStatus raw value: \(status.rawValue)")
        switch status {
        case .fullAccess, .authorized:
            isAuthorized = true
            completion(true)
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, error in
                NSLog("[CalendarAlerts] requestFullAccessToEvents: granted=\(granted) error=\(String(describing: error))")
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    completion(granted)
                }
            }
        default:
            isAuthorized = false
            completion(false)
        }
    }

    func availableCalendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).map { cal in
            var hex = "#888888"
            if let rgb = cal.color.usingColorSpace(.sRGB) {
                let r = Int((rgb.redComponent * 255).rounded())
                let g = Int((rgb.greenComponent * 255).rounded())
                let b = Int((rgb.blueComponent * 255).rounded())
                hex = String(format: "#%02X%02X%02X", r, g, b)
            }
            return CalendarInfo(id: cal.calendarIdentifier, title: cal.title, hexColor: hex)
        }
    }

    func nextEventToday(filteredTo calendarIDs: Set<String> = []) -> EKEvent? {
        guard isAuthorized else { return nil }
        let now = Date()
        let cal = Calendar.current
        guard let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return nil }

        let calendars: [EKCalendar]? = calendarIDs.isEmpty ? nil :
            store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }

        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: calendars)
        return store.events(matching: predicate)
            .filter { $0.startDate > now && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    // MARK: - Shared file reading (used by the plugin binary process)

    static func readEventsFromSharedFile() -> [SharedEvent] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/calendar-alerts-events.json")),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let startTS = dict["startDate"] as? TimeInterval else { return nil }
            return SharedEvent(
                title: title,
                startDate: Date(timeIntervalSince1970: startTS),
                endDate: Date(timeIntervalSince1970: (dict["endDate"] as? TimeInterval) ?? startTS),
                identifier: dict["identifier"] as? String ?? "",
                calendarIdentifier: dict["calendarIdentifier"] as? String ?? ""
            )
        }
    }

    static func nextEventFromSharedFile(filteredTo calendarIDs: Set<String> = []) -> SharedEvent? {
        let events = readEventsFromSharedFile()
        let now = Date()
        return events
            .filter { $0.startDate > now && (calendarIDs.isEmpty || calendarIDs.contains($0.calendarIdentifier)) }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    static func readCalendarsFromSharedFile() -> [CalendarInfo] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/calendar-alerts-calendars.json")),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String else { return nil }
            return CalendarInfo(id: id, title: title, hexColor: dict["color"] as? String ?? "#888888")
        }
    }
}
