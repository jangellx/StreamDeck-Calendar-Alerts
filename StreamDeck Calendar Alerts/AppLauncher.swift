import AppKit

// Opens whatever the key is set to open when pressed. In apps that support it,
// that's the event the key is showing, or at least its day:
//
//   Apple Calendar   the event   ical://ekevent/<calendarItemIdentifier>
//                                (undocumented; the form MeetingBar uses)
//   BusyCal          the event   busycalevent://find/<calendar>/<title>/<date-time>
//   Notion Calendar  the event   cron://showEvent?accountEmail=…&iCalUID=…&startDate=…&endDate=…
//   Fantastical      its day     x-fantastical://date/<yyyy-MM-dd>
//                                (Fantastical has no link to a single event)
//   Google Calendar  its day     https://calendar.google.com/calendar/r/day/<y>/<m>/<d>
//
// A reminder opens in Reminders, at the reminder, when its key is set to
// Reminders (or Calendar) (x-apple-reminderkit://REMCDReminder/<calendarItemIdentifier>,
// undocumented). Fantastical and Google Calendar show its day.
//
// Other apps and web calendars are simply opened.
enum AppLauncher {
    static let appleCalendarID = "com.apple.iCal"
    static let urlChoice = "url"   // the "openApp" setting value that means "open openURL"

    private static let fantasticalID = "com.flexibits.fantastical2.mac"
    private static let busyCalIDs: Set<String> = ["com.busymac.busycal3", "com.busymac.busycal-setapp"]
    private static let notionCalendarID = "com.cron.electron"
    static let remindersID = "com.apple.reminders"

    // Popular Mac apps offered at the top of the menu when they're installed.
    // Any other app that opens webcal: links is added to the calendar group too.
    private static let calendarApps = [
        appleCalendarID,
        fantasticalID,
        "com.busymac.busycal3",            // BusyCal
        "com.busymac.busycal-setapp",      // BusyCal from Setapp
        "com.microsoft.Outlook",           // Outlook
        notionCalendarID,                  // Notion Calendar
        "com.mowglii.ItsycalApp",          // Itsycal
        "com.sindresorhus.Dato",           // Dato
    ]
    private static let meetingAndTaskApps = [
        "us.zoom.xos",                     // Zoom
        "com.microsoft.teams2",            // Microsoft Teams
        "com.microsoft.teams",             // Microsoft Teams (classic)
        "Cisco-Systems.Spark",             // Webex
        "com.tinyspeck.slackmacgap",       // Slack
        "com.apple.reminders",             // Reminders
        "com.culturedcode.ThingsMac",      // Things
        "com.todoist.mac.Todoist",         // Todoist
        "com.omnigroup.OmniFocus4",        // OmniFocus
        "com.omnigroup.OmniFocus3",        // OmniFocus 3
        "com.TickTick.task.mac",           // TickTick
    ]

    // Web calendars, always offered. The setting value is the "web:" id.
    private static let webCalendars: [(id: String, name: String, url: String)] = [
        ("web:google", "Google Calendar", "https://calendar.google.com/calendar/r"),
        ("web:outlook", "Outlook on the web", "https://outlook.office.com/calendar/"),
        ("web:outlook-live", "Outlook.com", "https://outlook.live.com/calendar/"),
        ("web:icloud", "iCloud Calendar", "https://www.icloud.com/calendar/"),
        ("web:proton", "Proton Calendar", "https://calendar.proton.me/"),
    ]

    // What pressing the key shows for a choice: "event", "day", or nil (just opens it).
    static func opens(_ choice: String) -> String? {
        if choice == appleCalendarID || choice == notionCalendarID || busyCalIDs.contains(choice) { return "event" }
        if choice == fantasticalID || choice == "web:google" { return "day" }
        return nil
    }

    // MARK: - Menu contents

    // Installed apps for the top of the menu, tagged with a group ("calendar" or
    // "other") and what a press opens. Apple Calendar comes first.
    static func suggestedApps() -> [[String: String]] {
        var seen = Set<String>()
        var result: [[String: String]] = []

        var calendarURLs = calendarApps.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        if let webcal = URL(string: "webcal://example.com/calendar.ics") {
            calendarURLs += NSWorkspace.shared.urlsForApplications(toOpen: webcal)
        }
        let otherURLs = meetingAndTaskApps.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

        for (urls, group) in [(calendarURLs, "calendar"), (otherURLs, "other")] {
            let apps = urls.compactMap(appInfo).filter { seen.insert($0.id).inserted }
            for app in sortedByName(apps) {
                result.append(menuEntry(id: app.id, name: app.name, group: group))
            }
        }
        return result
    }

    static func webCalendarChoices() -> [[String: String]] {
        webCalendars.map { menuEntry(id: $0.id, name: $0.name, group: "web") }
    }

    // Every app in the usual Applications folders, for "Another app…".
    static func allApps() -> [[String: String]] {
        let folders = [
            "/Applications", "/Applications/Utilities", "/Applications/Setapp",
            "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var seen = Set<String>()
        var apps: [(id: String, name: String)] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for item in items where item.hasSuffix(".app") {
                guard let app = appInfo(URL(fileURLWithPath: folder).appendingPathComponent(item)),
                      seen.insert(app.id).inserted else { continue }
                apps.append(app)
            }
        }
        return sortedByName(apps).map { menuEntry(id: $0.id, name: $0.name, group: "all") }
    }

    private static func menuEntry(id: String, name: String, group: String) -> [String: String] {
        var entry = ["id": id, "name": name, "group": group]
        if let opens = opens(id) { entry["opens"] = opens }
        return entry
    }

    // MARK: - Opening

    // Opens the chosen app, web calendar or URL, showing `event` where the app
    // supports it. Falls back to Apple Calendar if the chosen app is missing.
    static func open(choice: String, url urlString: String, event: SharedEvent?) {
        if let web = webCalendars.first(where: { $0.id == choice }) {
            if let link = event.flatMap({ webEventLink(choice, event: $0) }) ?? URL(string: web.url) {
                NSWorkspace.shared.open(link)
            }
            return
        }
        if choice == urlChoice, let url = webURL(from: urlString) {
            NSWorkspace.shared.open(url)
            return
        }

        var bundleID = choice
        // A reminder belongs in Reminders rather than Calendar.
        if event?.isReminder == true, choice == appleCalendarID { bundleID = remindersID }
        var appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        if appURL == nil {
            bundleID = appleCalendarID
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appleCalendarID)
        }
        guard let appURL else { return }

        let config = NSWorkspace.OpenConfiguration()
        let report: (NSRunningApplication?, Error?) -> Void = { _, error in
            if let error { NSLog("[CalendarAlerts] Couldn't open \(appURL.lastPathComponent): \(error)") }
        }
        if let event, let link = eventLink(for: bundleID, event: event) {
            // Hand the link to the chosen app specifically, not whatever owns the scheme.
            NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: config, completionHandler: report)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: report)
        }
    }

    // Joins the event's video meeting. Zoom and Teams links go straight to their
    // apps when installed, rather than through a browser page that hands off.
    static func joinMeeting(_ link: String) {
        guard var url = URL(string: link), url.scheme == "https" else { return }
        if let host = url.host?.lowercased(), host.hasSuffix("zoom.us") || host.hasSuffix("zoomgov.com"),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil,
           let app = zoomAppLink(url) {
            url = app
        } else if url.host?.lowercased() == "teams.microsoft.com",
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.teams2") != nil,
                  let app = URL(string: "msteams:" + url.absoluteString.dropFirst("https://teams.microsoft.com".count)) {
            url = app
        }
        NSWorkspace.shared.open(url)
    }

    // https://us02web.zoom.us/j/123456789?pwd=abc → zoommtg://us02web.zoom.us/join?confno=123456789&pwd=abc
    private static func zoomAppLink(_ url: URL) -> URL? {
        let parts = url.pathComponents   // ["/", "j", "123456789"]
        guard parts.count >= 3, parts[1] == "j", let host = url.host,
              var components = URLComponents(string: "zoommtg://\(host)/join") else { return nil }
        var query = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: parts[2])]
        if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pwd" })?.value {
            query.append(URLQueryItem(name: "pwd", value: pwd))
        }
        components.queryItems = query
        return components.url
    }

    static func eventLink(for bundleID: String, event: SharedEvent) -> URL? {
        if event.isReminder {
            switch bundleID {
            case remindersID:
                guard !event.calendarItemIdentifier.isEmpty else { return nil }
                return URL(string: "x-apple-reminderkit://REMCDReminder/\(encode(event.calendarItemIdentifier))")
            case fantasticalID:
                return URL(string: "x-fantastical://date/\(localDay(event.startDate))")
            default:
                return nil
            }
        }
        switch bundleID {
        case appleCalendarID:
            guard !event.calendarItemIdentifier.isEmpty else { return nil }
            return URL(string: "ical://ekevent/\(encode(event.calendarItemIdentifier))")
        case fantasticalID:
            return URL(string: "x-fantastical://date/\(localDay(event.startDate))")
        case _ where busyCalIDs.contains(bundleID):
            let time = format(event.startDate, "yyyy-MM-dd'T'HH:mm:ssZ", utc: true)
            return URL(string: "busycalevent://find/\(encode(event.calendarTitle))/\(encode(event.title))/\(encode(time))")
        case notionCalendarID:
            // Notion Calendar needs the account the event belongs to.
            guard !event.accountEmail.isEmpty, !event.externalIdentifier.isEmpty else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let query = [
                ("accountEmail", event.accountEmail),
                ("iCalUID", event.externalIdentifier),
                ("startDate", iso.string(from: event.startDate)),
                ("endDate", iso.string(from: event.endDate)),
                ("title", event.title),
                ("ref", "com.joeangell.calendar-alerts"),
            ].map { "\($0)=\(encode($1))" }.joined(separator: "&")
            return URL(string: "cron://showEvent?\(query)")
        default:
            return nil
        }
    }

    static func webEventLink(_ choice: String, event: SharedEvent) -> URL? {
        guard choice == "web:google" else { return nil }
        let day = Calendar.current.dateComponents([.year, .month, .day], from: event.startDate)
        guard let y = day.year, let m = day.month, let d = day.day else { return nil }
        var link = "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(d)"
        // Open the Google account the event belongs to, if there are several.
        if !event.accountEmail.isEmpty { link += "?authuser=" + encode(event.accountEmail) }
        return URL(string: link)
    }

    // MARK: - Helpers

    private static func appInfo(_ url: URL) -> (id: String, name: String)? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return (id, name)
    }

    // Alphabetical, with Apple Calendar always first.
    private static func sortedByName(_ apps: [(id: String, name: String)]) -> [(id: String, name: String)] {
        apps.sorted { a, b in
            if a.id == appleCalendarID { return b.id != appleCalendarID }
            if b.id == appleCalendarID { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // Percent-encodes everything except RFC 3986 unreserved characters, so a
    // title containing "/" or "&" can't break a path or query.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static func localDay(_ date: Date) -> String { format(date, "yyyy-MM-dd", utc: false) }

    private static func format(_ date: Date, _ pattern: String, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // Accepts "calendar.google.com" as well as full URLs and custom schemes
    // like "x-fantastical3://".
    private static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") { return URL(string: trimmed) }
        return URL(string: "https://" + trimmed)
    }
}
