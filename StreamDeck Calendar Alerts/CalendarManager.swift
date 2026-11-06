import Foundation

struct CalendarInfo {
    let id: String
    let title: String
    let hexColor: String
}

// Whether the helper can read reminders: "granted", "denied", or "notDetermined"
// (not asked yet, because no key has shown reminders).
enum RemindersAccess: String {
    case granted, denied, notDetermined
}

struct SharedEvent {
    let title: String
    let startDate: Date
    let endDate: Date
    let identifier: String
    let calendarIdentifier: String
    var isAllDay = false                // for a reminder: due today with no time
    var isReminder = false              // a reminder rather than a calendar event

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
    static let reminderListsURL = directory.appendingPathComponent("reminder-lists.json")
    // Written by the plugin while any key shows reminders. The helper only asks for
    // reminders access once it exists, so nobody who never uses them is asked.
    static let remindersWantedURL = directory.appendingPathComponent("reminders-wanted")

    // Plugin → helper, through the distributed notification center (same user only).
    static let remindersWantedNotification = Notification.Name("com.joeangell.calendar-alerts.remindersWanted")
    static let setReminderCompletedNotification = Notification.Name("com.joeangell.calendar-alerts.setReminderCompleted")

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

    static func remindersAccess() -> RemindersAccess {
        guard let status = readJSON(statusURL) as? [String: Any],
              let value = status["reminders"] as? String else { return .notDetermined }
        return RemindersAccess(rawValue: value) ?? .notDetermined
    }

    // Asks the helper to read reminders, asking for access first if it hasn't yet.
    static func requestReminders() {
        if !FileManager.default.fileExists(atPath: remindersWantedURL.path) {
            writeJSON(["wanted": true], to: remindersWantedURL)
        }
        DistributedNotificationCenter.default().postNotificationName(
            remindersWantedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // Asks the helper to mark a reminder done (or not done again).
    static func setReminder(_ identifier: String, completed: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            setReminderCompletedNotification, object: nil,
            userInfo: ["identifier": identifier, "completed": completed], deliverImmediately: true)
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
                isAllDay: dict["allDay"] as? Bool ?? false,
                isReminder: dict["reminder"] as? Bool ?? false,
                calendarItemIdentifier: dict["calendarItemIdentifier"] as? String ?? "",
                externalIdentifier: dict["externalIdentifier"] as? String ?? "",
                calendarTitle: dict["calendarTitle"] as? String ?? "",
                accountEmail: dict["accountEmail"] as? String ?? ""
            )
        }
    }

    // What a key can show today:
    //   next    the next timed event or reminder still to come
    //   allDay  all-day events covering now, reminders due today with no time, and
    //           timed reminders due earlier today that aren't done yet. Reminders
    //           come first (overdue, then by time), so marking one done moves the
    //           key on; then events by calendar and title, a steady order so the key
    //           doesn't jump between them.
    struct Filter {
        var events = true
        var reminders = false
        var calendarIDs: Set<String> = []       // empty = all calendars
        var reminderListIDs: Set<String> = []   // empty = all lists
        var hidden: Set<String> = []            // reminders just marked done
    }

    static func today(_ filter: Filter) -> (next: SharedEvent?, allDay: [SharedEvent]) {
        let now = Date()
        let items = readEventsFromSharedFile().filter { item in
            if item.isReminder {
                return filter.reminders && !filter.hidden.contains(item.calendarItemIdentifier)
                    && (filter.reminderListIDs.isEmpty || filter.reminderListIDs.contains(item.calendarIdentifier))
            }
            return filter.events && (filter.calendarIDs.isEmpty || filter.calendarIDs.contains(item.calendarIdentifier))
        }
        let next = items
            .filter { !$0.isAllDay && $0.startDate > now }
            .min { $0.startDate < $1.startDate }
        let reminders = items
            .filter { $0.isReminder && ($0.isAllDay || $0.startDate <= now) }
            .sorted { a, b in
                // Overdue timed reminders, earliest first, then the ones for today.
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                return (a.startDate, a.title) < (b.startDate, b.title)
            }
        let events = items
            .filter { !$0.isReminder && $0.isAllDay && $0.startDate <= now && $0.endDate > now }
            .sorted { ($0.calendarTitle, $0.title) < ($1.calendarTitle, $1.title) }
        return (next, reminders + events)
    }

    static func readCalendarsFromSharedFile() -> [CalendarInfo] { readCalendarList(calendarsURL) }
    static func readReminderListsFromSharedFile() -> [CalendarInfo] { readCalendarList(reminderListsURL) }

    private static func readCalendarList(_ url: URL) -> [CalendarInfo] {
        guard let array = readJSON(url) as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String else { return nil }
            return CalendarInfo(id: id, title: title, hexColor: dict["color"] as? String ?? "#888888")
        }
    }
}
