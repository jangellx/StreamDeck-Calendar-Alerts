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
    private var noEventsStyle = "moon"                          // moon | smile | smile-dark | check | check-emoji | thumbs | crescent | text | message | custom
    private var noEventsMessage = ""                            // the user's words for "message"
    private var noEventsImage = ""                              // data: URL for "custom"

    private static let alertMinutes: Set<Int> = [60, 30, 15, 5]

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
        if minuteTimer != nil { update() }
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

        guard let event = CalendarManager.nextEventFromSharedFile(filteredTo: selectedCalendarIDs) else {
            resetEventState()
            sendImage(ButtonImageRenderer.shared.renderNoEvents(style: noEventsStyle, customImage: noEventsImage,
                                                                customMessage: noEventsMessage))
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

        if Self.alertMinutes.contains(minutesUntil), !soundsPlayed.contains(minutesUntil) {
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
