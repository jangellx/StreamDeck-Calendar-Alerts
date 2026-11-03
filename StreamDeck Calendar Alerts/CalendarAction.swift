import Foundation
import AudioToolbox
import EventKit

final class CalendarAction {
    let context: String
    weak var plugin: StreamDeckPlugin?

    private var minuteTimer: Timer?
    private var flashTimer: Timer?
    private var flashPhase = false
    private var currentEvent: SharedEvent?
    private var currentEventID: String?
    private var soundsPlayed: Set<Int> = []
    private var selectedCalendarIDs: Set<String> = []

    private static let alertMinutes: Set<Int> = [60, 30, 15, 5]

    init(context: String, plugin: StreamDeckPlugin) {
        self.context = context
        self.plugin = plugin
    }

    func applySettings(_ settings: [String: Any]) {
        let ids = settings["selectedCalendars"] as? [String] ?? []
        selectedCalendarIDs = Set(ids)
        if minuteTimer != nil { update() }
    }

    func handleFromPI(_ payload: [String: Any]) {
        guard let request = payload["request"] as? String, request == "getCalendars" else { return }
        let calendars = CalendarManager.readCalendarsFromSharedFile()
        let data = calendars.map { ["id": $0.id, "title": $0.title, "color": $0.hexColor] as [String: Any] }
        plugin?.sendToPropertyInspector(context: context, payload: ["calendars": data])
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
        guard let plugin else { return }

        if let event = CalendarManager.nextEventFromSharedFile(filteredTo: selectedCalendarIDs) {
            currentEvent = event
            let minutesUntil = max(0, Int(event.startDate.timeIntervalSinceNow / 60))

            if event.identifier != currentEventID {
                currentEventID = event.identifier
                soundsPlayed = []
            }

            if Self.alertMinutes.contains(minutesUntil), !soundsPlayed.contains(minutesUntil) {
                soundsPlayed.insert(minutesUntil)
                AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
            }

            if minutesUntil == 0 {
                startFlashing()
            } else {
                stopFlashing()
                sendImage(for: event, minutesUntil: minutesUntil, flashPhase: false)
            }
        } else {
            currentEvent = nil
            currentEventID = nil
            soundsPlayed = []
            stopFlashing()
            let image = ButtonImageRenderer.shared.renderNoMeetings()
            plugin.send([
                "event": "setImage",
                "context": context,
                "payload": ["image": image, "target": 0]
            ])
        }
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
        sendImage(for: event, minutesUntil: 0, flashPhase: flashPhase)
    }

    private func sendImage(for event: SharedEvent, minutesUntil: Int, flashPhase: Bool) {
        guard let plugin else { return }
        let image = ButtonImageRenderer.shared.renderEvent(
            title: event.title,
            minutesUntil: minutesUntil,
            flashPhase: flashPhase
        )
        plugin.send([
            "event": "setImage",
            "context": context,
            "payload": ["image": image, "target": 0]
        ])
    }

    func openCalendar() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Calendar"]
        try? proc.run()
    }
}
