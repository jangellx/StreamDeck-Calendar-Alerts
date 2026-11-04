import AppKit

// Opens whatever the key is set to open when pressed: a calendar app, or a URL
// (for web calendars such as Google Calendar).
enum AppLauncher {
    static let appleCalendarID = "com.apple.iCal"
    static let urlChoice = "url"   // the "openApp" setting value that means "open openURL"

    // Calendar apps that may not register for webcal: links, checked by bundle ID.
    private static let knownCalendarApps = [
        appleCalendarID,
        "com.flexibits.fantastical2.mac",  // Fantastical
        "com.busymac.busycal3",            // BusyCal
        "com.microsoft.Outlook",           // Outlook
        "com.cron.electron",               // Notion Calendar
    ]

    // Installed calendar apps for the settings panel, Apple Calendar first.
    static func installedCalendarApps() -> [[String: String]] {
        var urls: [URL] = []
        if let webcal = URL(string: "webcal://example.com/calendar.ics") {
            urls += NSWorkspace.shared.urlsForApplications(toOpen: webcal)
        }
        urls += knownCalendarApps.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

        var seen = Set<String>()
        var apps: [(id: String, name: String)] = []
        for url in urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            apps.append((id, name))
        }
        apps.sort { a, b in
            if a.id == appleCalendarID { return true }
            if b.id == appleCalendarID { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return apps.map { ["id": $0.id, "name": $0.name] }
    }

    // Opens the chosen app or URL, falling back to Apple Calendar if it can't.
    static func open(app bundleID: String, url urlString: String) {
        if bundleID == urlChoice, let url = webURL(from: urlString) {
            NSWorkspace.shared.open(url)
            return
        }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appleCalendarID)
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("[CalendarAlerts] Couldn't open \(appURL.path): \(error)") }
        }
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
