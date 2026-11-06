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
    private var openReminderApp = AppLauncher.remindersID      // the same, for a reminder on the key
    private var openReminderURL = ""
    private var noEventsStyle = "moon"                          // see ButtonImageRenderer.renderNoEvents
    private var noEventsMessage = ""                            // the user's words for "message"
    private var noEventsImage = ""                              // data: URL for "custom"
    private var showAllDay = true                               // show all-day events when nothing else is left
    private var allDayUntil: Int?                               // minutes after midnight to stop showing them; nil = all day
    private var playAlerts = true
    private var alertMinutes: Set<Int> = CalendarAction.defaultAlertMinutes
    private var alertEveryMinute = false                        // also at 4, 3, 2 and 1 minutes
    private var showEvents = true                               // calendar events
    private var showReminders = false                           // reminders due today
    private var selectedReminderListIDs: Set<String> = []       // empty = all lists
    private var showTimed = true                                // events and reminders at a set time

    static let defaultAlertMinutes: Set<Int> = [60, 30, 15, 5]

    // Pressing the key. A tap opens the app. Holding the key or tapping it twice
    // marks a reminder on it done (doing that again while "Done" shows marks it not
    // done), or joins the video meeting of an event on it. Each kind can swap the
    // two, so a tap does the second thing. Stream Deck only reports the key going
    // down and up, so holds and double taps are timed here.
    private var swapEventPress = false                          // tap joins the meeting
    private var swapReminderPress = false                       // tap marks the reminder done
    static let holdTime: TimeInterval = 0.5
    static let doubleTapTime: TimeInterval = 0.3
    static let undoTime: TimeInterval = 5
    private var holdTimer: Timer?
    private var tapTimer: Timer?                                // a tap waiting to see if a second one follows
    private var holdHandled = false

    // A reminder marked done from this key: shown as done for a few seconds (when
    // a second hold or double tap undoes it), and kept off the key afterwards
    // until the helper's next file no longer lists it.
    private var doneReminder: SharedEvent?
    private var doneTimer: Timer?
    private var hiddenReminderIDs: [String: Date] = [:]

    init(context: String, plugin: StreamDeckPlugin) {
        self.context = context
        self.plugin = plugin
    }

    func applySettings(_ settings: [String: Any]) {
        selectedCalendarIDs = Set(settings["selectedCalendars"] as? [String] ?? [])
        openApp       = settings["openApp"] as? String ?? AppLauncher.appleCalendarID
        openURL       = settings["openURL"] as? String ?? ""
        openReminderApp = settings["openReminderApp"] as? String ?? AppLauncher.remindersID
        openReminderURL = settings["openReminderURL"] as? String ?? ""
        noEventsStyle = settings["noEventsStyle"] as? String ?? "moon"
        noEventsMessage = settings["noEventsMessage"] as? String ?? ""
        noEventsImage = settings["noEventsImage"] as? String ?? ""
        showAllDay    = settings["showAllDay"] as? Bool ?? true
        allDayUntil   = Self.minutesAfterMidnight(settings["allDayUntil"] as? String ?? "")
        playAlerts    = settings["playAlerts"] as? Bool ?? true
        alertMinutes  = (settings["alertMinutes"] as? [Int]).map(Set.init) ?? Self.defaultAlertMinutes
        alertEveryMinute = settings["alertEveryMinute"] as? Bool ?? false
        showEvents    = settings["showEvents"] as? Bool ?? true
        showReminders = settings["showReminders"] as? Bool ?? false
        selectedReminderListIDs = Set(settings["selectedReminderLists"] as? [String] ?? [])
        showTimed     = settings["showTimed"] as? Bool ?? true
        swapEventPress = settings["swapEventPress"] as? Bool ?? false
        swapReminderPress = settings["swapReminderPress"] as? Bool ?? false
        if showReminders { CalendarManager.requestReminders() }
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
        holdTimer?.invalidate()
        tapTimer?.invalidate()
        doneTimer?.invalidate()
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

        // A reminder just marked done keeps the key until its moment to undo passes.
        if let done = doneReminder {
            stopFlashing()
            currentEvent = done
            sendImage(ButtonImageRenderer.shared.renderReminderDone(title: done.title))
            return
        }

        // Reminders the helper still lists a minute after being marked done
        // weren't saved; let them back.
        hiddenReminderIDs = hiddenReminderIDs.filter { $0.value.timeIntervalSinceNow > -60 }
        var filter = CalendarManager.Filter()
        filter.events = showEvents
        filter.reminders = showReminders && CalendarManager.remindersAccess() == .granted
        filter.calendarIDs = selectedCalendarIDs
        filter.reminderListIDs = selectedReminderListIDs
        filter.hidden = Set(hiddenReminderIDs.keys)
        let today = CalendarManager.today(filter)
        guard let event = showTimed ? today.next : nil else {
            resetEventState()
            if let allDay = allDayEventToShow(today.allDay) {
                // Pressing the key opens it, like a timed event.
                currentEvent = allDay
                let label = !allDay.isReminder ? "All day" : allDay.isAllDay ? "Today" : "Overdue"
                sendImage(ButtonImageRenderer.shared.renderAllDay(title: allDay.title,
                                                                  others: today.allDay.count - 1,
                                                                  label: label, reminder: allDay.isReminder))
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
            flashPhase: flashPhase,
            reminder: event.isReminder
        ))
    }

    private func sendImage(_ image: String) {
        plugin?.send([
            "event": "setImage",
            "context": context,
            "payload": ["image": image, "target": 0]
        ])
    }

    // Opens the app chosen for what's on the key (events and reminders each have
    // their own), showing the item where the app supports it.
    func openConfiguredApp() {
        if currentEvent?.isReminder == true {
            AppLauncher.open(choice: openReminderApp, url: openReminderURL, event: currentEvent)
        } else {
            AppLauncher.open(choice: openApp, url: openURL, event: currentEvent)
        }
    }

    // MARK: - Pressing the key

    // The reminder a hold or double tap acts on, if one is on the key.
    private var reminderOnKey: SharedEvent? {
        doneReminder ?? (currentEvent?.isReminder == true ? currentEvent : nil)
    }

    // The meeting link of the event on the key, if it has one.
    private var meetingOnKey: String? {
        guard reminderOnKey == nil, let link = currentEvent?.meetingURL, !link.isEmpty else { return nil }
        return link
    }

    // Whether a hold or double tap would do something other than a tap. If not,
    // a tap acts at once instead of waiting to see if a second tap follows.
    private var hasSecondAction: Bool { reminderOnKey != nil || meetingOnKey != nil }

    private enum Press { case tap, holdOrDoubleTap }

    private func perform(_ press: Press) {
        if reminderOnKey != nil {
            (press == .tap) != swapReminderPress ? openConfiguredApp() : toggleReminder()
        } else if let link = meetingOnKey, (press == .tap) == swapEventPress {
            AppLauncher.joinMeeting(link)
        } else {
            openConfiguredApp()
        }
    }

    func keyDown() {
        holdHandled = false
        holdTimer?.invalidate()
        guard hasSecondAction else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.holdHandled = true
            self.tapTimer?.invalidate()
            self.tapTimer = nil
            self.perform(.holdOrDoubleTap)
        }
    }

    func keyUp() {
        holdTimer?.invalidate()
        holdTimer = nil
        if holdHandled { return }
        guard hasSecondAction else {
            perform(.tap)
            return
        }
        if tapTimer != nil {
            // The second tap of a double tap.
            tapTimer?.invalidate()
            tapTimer = nil
            perform(.holdOrDoubleTap)
            return
        }
        tapTimer = Timer.scheduledTimer(withTimeInterval: Self.doubleTapTime, repeats: false) { [weak self] _ in
            self?.tapTimer = nil
            self?.perform(.tap)
        }
    }

    // Marks the reminder on the key done, or, while "Done" shows, not done again.
    private func toggleReminder() {
        if let done = doneReminder {
            CalendarManager.setReminder(done.calendarItemIdentifier, completed: false)
            hiddenReminderIDs.removeValue(forKey: done.calendarItemIdentifier)
            doneReminder = nil
            doneTimer?.invalidate()
            doneTimer = nil
            update()
            return
        }
        guard let reminder = reminderOnKey else { return }
        CalendarManager.setReminder(reminder.calendarItemIdentifier, completed: true)
        hiddenReminderIDs[reminder.calendarItemIdentifier] = Date()
        doneReminder = reminder
        update()
        doneTimer = Timer.scheduledTimer(withTimeInterval: Self.undoTime, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.doneReminder = nil
            self.doneTimer = nil
            self.update()
        }
    }
}
