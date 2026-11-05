import Foundation
import AudioToolbox

final class CalendarAction {
    let context: String
    weak var plugin: StreamDeckPlugin?

    private var minuteTimer: Timer?
    private var flashTimer: Timer?
    private var flashPhase = false
    private var currentEvent: SharedEvent?
    private var currentEventKey: String?
    private var soundsPlayed: Set<Int> = []

    // Per-key settings, saved by the property inspector.
    private var selectedCalendarIDs: Set<String> = []          // empty = all calendars
    private var openApp = AppLauncher.appleCalendarID          // bundle ID, or AppLauncher.urlChoice
    private var openURL = ""
    private var noEventsStyle = "moon"                          // see ButtonImageRenderer.renderNoEvents
    private var noEventsMessage = ""                            // the user's words for "message"
    private var noEventsImage = ""                              // data: URL for "custom"
    private var showAllDay = true                               // show all-day events when nothing else is left
    private var allDayUntil: Int?                               // minutes after midnight to stop showing them; nil = all day
    private var playAlerts = true
    private var alertMinutes: Set<Int> = CalendarAction.defaultAlertMinutes
    private var alertEveryMinute = false                        // also at 4, 3, 2 and 1 minutes

    static let defaultAlertMinutes: Set<Int> = [60, 30, 15, 5]

    init(context: String, plugin: StreamDeckPlugin) {
        self.context = context
        self.plugin = plugin
    }

    func applySettings(_ settings: [String: Any]) {
        selectedCalendarIDs = Set(settings["selectedCalendars"] as? [String] ?? [])
        openApp       = settings["openApp"] as? String ?? AppLauncher.appleCalendarID
        openURL       = settings["openURL"] as? String ?? ""
        noEventsStyle = settings["noEventsStyle"] as? String ?? "moon"
        noEventsMessage = settings["noEventsMessage"] as? String ?? ""
        noEventsImage = settings["noEventsImage"] as? String ?? ""
        showAllDay    = settings["showAllDay"] as? Bool ?? true
        allDayUntil   = Self.minutesAfterMidnight(settings["allDayUntil"] as? String ?? "")
        playAlerts    = settings["playAlerts"] as? Bool ?? true
        alertMinutes  = (settings["alertMinutes"] as? [Int]).map(Set.init) ?? Self.defaultAlertMinutes
        alertEveryMinute = settings["alertEveryMinute"] as? Bool ?? false
        if minuteTimer != nil { update() }
    }

    // "17:30" → 1050. Anything else (including "") → nil.
    private static func minutesAfterMidnight(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    // Whether an alert should sound this many minutes before an event.
    private func alertsAt(_ minutes: Int) -> Bool {
        guard playAlerts else { return false }
        return alertMinutes.contains(minutes) || (alertEveryMinute && (1...5).contains(minutes))
    }

    // The all-day event to show when no timed event is left today, if any.
    private func allDayEventToShow(_ events: [SharedEvent]) -> SharedEvent? {
        guard showAllDay, let first = events.first else { return nil }
        if let cutoff = allDayUntil {
            let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
            if (now.hour ?? 0) * 60 + (now.minute ?? 0) >= cutoff { return nil }
        }
        return first
    }

    func start() {
        update()
        scheduleNextMinuteTick()
    }

    func stop() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        stopFlashing()
    }

    // Fire exactly at the next minute boundary, then every 60 s thereafter,
    // so the countdown always flips the instant the clock minute changes.
    private func scheduleNextMinuteTick() {
        let now = Date()
        let nextMinute = Date(timeIntervalSinceReferenceDate:
            (now.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)

        minuteTimer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(minuteTimer!, forMode: .common)
    }

    func update() {
        if CalendarManager.accessDenied() {
            resetEventState()
            sendImage(ButtonImageRenderer.shared.renderNoAccess())
            return
        }

        let today = CalendarManager.todaysEventsFromSharedFile(filteredTo: selectedCalendarIDs)
        guard let event = today.next else {
            resetEventState()
            if let allDay = allDayEventToShow(today.allDay) {
                // Pressing the key opens it, like a timed event.
                currentEvent = allDay
                sendImage(ButtonImageRenderer.shared.renderAllDay(title: allDay.title,
                                                                  others: today.allDay.count - 1))
            } else {
                sendImage(ButtonImageRenderer.shared.renderNoEvents(style: noEventsStyle, customImage: noEventsImage,
                                                                    customMessage: noEventsMessage))
            }
            return
        }

        currentEvent = event
        if event.occurrenceKey != currentEventKey {
            currentEventKey = event.occurrenceKey
            soundsPlayed = []
        }

        // Ticks land a few milliseconds after each minute boundary, so round up:
        // at 10:00 a 10:30 meeting is 30 minutes away, not 29.
        let secondsUntil = event.startDate.timeIntervalSinceNow
        let minutesUntil = Int((secondsUntil / 60).rounded(.up))

        if alertsAt(minutesUntil), !soundsPlayed.contains(minutesUntil) {
            soundsPlayed.insert(minutesUntil)
            AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
        }

        // Flash "NOW" through the final minute before the meeting starts.
        if secondsUntil <= 60 {
            startFlashing()
        } else {
            stopFlashing()
            sendEventImage(event, minutesUntil: minutesUntil, flashPhase: false)
        }
    }

    private func resetEventState() {
        currentEvent = nil
        currentEventKey = nil
        soundsPlayed = []
        stopFlashing()
    }

    private func startFlashing() {
        guard flashTimer == nil else { return }
        flashPhase = false
        sendFlashFrame()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.flashPhase.toggle()
            self.sendFlashFrame()
        }
        RunLoop.main.add(flashTimer!, forMode: .common)
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashPhase = false
    }

    private func sendFlashFrame() {
        guard let event = currentEvent else { return }
        sendEventImage(event, minutesUntil: 0, flashPhase: flashPhase)
    }

    private func sendEventImage(_ event: SharedEvent, minutesUntil: Int, flashPhase: Bool) {
        sendImage(ButtonImageRenderer.shared.renderEvent(
            title: event.title,
            minutesUntil: minutesUntil,
            flashPhase: flashPhase
        ))
    }

    private func sendImage(_ image: String) {
        plugin?.send([
            "event": "setImage",
            "context": context,
            "payload": ["image": image, "target": 0]
        ])
    }

    // Opens the chosen app, showing the event on the key where the app supports it.
    func openConfiguredApp() {
        AppLauncher.open(choice: openApp, url: openURL, event: currentEvent)
    }
}
