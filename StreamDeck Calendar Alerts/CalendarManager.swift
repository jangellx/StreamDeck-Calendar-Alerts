import Foundation

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

    // For opening the event in a calendar app (see AppLauncher.eventLink).
    var calendarItemIdentifier = ""     // EventKit's local ID; Apple Calendar's ical:// links
    var externalIdentifier = ""         // the iCalendar UID, shared with the server
    var calendarTitle = ""
    var accountEmail = ""               // empty when macOS doesn't say

    // eventIdentifier is shared by every occurrence of a recurring event, so
    // include the start time to tell two occurrences on the same day apart.
    var occurrenceKey: String { "\(identifier)@\(startDate.timeIntervalSince1970)" }
}

// CalendarHelper.app (CalendarServiceRunner) reads EventKit and writes these files;
// the plugin binary only reads them. They live in the user's own Caches folder
// rather than /tmp so other accounts on the Mac can't read event titles.
enum CalendarManager {
    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.joeangell.calendar-alerts", isDirectory: true)
    }()

    static let eventsURL    = directory.appendingPathComponent("events.json")
    static let calendarsURL = directory.appendingPathComponent("calendars.json")
    static let statusURL    = directory.appendingPathComponent("status.json")

    // Writes atomically so the plugin never reads a half-written file.
    static func writeJSON(_ object: Any, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[CalendarAlerts] Failed to write \(url.lastPathComponent): \(error)")
        }
    }

    private static func readJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // True only when the helper has reported that calendar access was refused.
    // A missing status file means the helper hasn't started yet, not a denial.
    static func accessDenied() -> Bool {
        guard let status = readJSON(statusURL) as? [String: Any],
              let authorized = status["authorized"] as? Bool else { return false }
        return !authorized
    }

    static func readEventsFromSharedFile() -> [SharedEvent] {
        guard let array = readJSON(eventsURL) as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let startTS = dict["startDate"] as? TimeInterval else { return nil }
            return SharedEvent(
                title: title,
                startDate: Date(timeIntervalSince1970: startTS),
                endDate: Date(timeIntervalSince1970: (dict["endDate"] as? TimeInterval) ?? startTS),
                identifier: dict["identifier"] as? String ?? "",
                calendarIdentifier: dict["calendarIdentifier"] as? String ?? "",
                calendarItemIdentifier: dict["calendarItemIdentifier"] as? String ?? "",
                externalIdentifier: dict["externalIdentifier"] as? String ?? "",
                calendarTitle: dict["calendarTitle"] as? String ?? "",
                accountEmail: dict["accountEmail"] as? String ?? ""
            )
        }
    }

    static func nextEventFromSharedFile(filteredTo calendarIDs: Set<String> = []) -> SharedEvent? {
        let now = Date()
        return readEventsFromSharedFile()
            .filter { $0.startDate > now && (calendarIDs.isEmpty || calendarIDs.contains($0.calendarIdentifier)) }
            .min { $0.startDate < $1.startDate }
    }

    static func readCalendarsFromSharedFile() -> [CalendarInfo] {
        guard let array = readJSON(calendarsURL) as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String else { return nil }
            return CalendarInfo(id: id, title: title, hexColor: dict["color"] as? String ?? "#888888")
        }
    }
}
