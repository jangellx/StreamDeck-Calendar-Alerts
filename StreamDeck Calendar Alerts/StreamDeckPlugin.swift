import Foundation

final class StreamDeckPlugin: NSObject {
    private let port: Int
    private let uuid: String
    private let registerEvent: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var actions: [String: CalendarAction] = [:]

    init(port: Int, uuid: String, registerEvent: String) {
        self.port = port
        self.uuid = uuid
        self.registerEvent = registerEvent
    }

    func connect() {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
    }

    // Send a command to StreamDeck.
    func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { _ in }
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text)
            case .success:
                break // Stream Deck only sends text frames.
            case .failure(let error):
                // The connection to Stream Deck is gone, so there's nothing left to
                // do. Calling receive() again would fail at once and spin forever.
                NSLog("[CalendarAlerts] WebSocket receive failed: \(error) — exiting")
                exit(0)
            }
            self.listen()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return }

        let context = json["context"] as? String ?? ""

        switch event {
        case "willAppear":
            let payload = json["payload"] as? [String: Any] ?? [:]
            let settings = payload["settings"] as? [String: Any] ?? [:]
            actions[context]?.stop()  // don't leak timers if willAppear repeats
            let action = CalendarAction(context: context, plugin: self)
            actions[context] = action
            action.applySettings(settings)
            action.start()
        case "willDisappear":
            actions[context]?.stop()
            actions.removeValue(forKey: context)
        case "keyDown":
            actions[context]?.openCalendar()
        case "didReceiveSettings":
            let payload = json["payload"] as? [String: Any] ?? [:]
            let settings = payload["settings"] as? [String: Any] ?? [:]
            actions[context]?.applySettings(settings)
        case "sendToPlugin":
            let payload = json["payload"] as? [String: Any] ?? [:]
            if payload["request"] as? String == "getCalendars" {
                // Answered here rather than by the action, so the PI gets data even
                // if willAppear hasn't arrived for this context yet.
                sendCalendarList(context: context)
            }
        default:
            break
        }
    }

    private func sendCalendarList(context: String) {
        let calendars = CalendarManager.readCalendarsFromSharedFile()
            .map { ["id": $0.id, "title": $0.title, "color": $0.hexColor] }
        sendToPropertyInspector(context: context, payload: [
            "calendars": calendars,
            "needsPermission": CalendarManager.accessDenied()
        ])
    }

    func sendToPropertyInspector(context: String, payload: [String: Any]) {
        send([
            "event": "sendToPropertyInspector",
            "action": "com.joeangell.calendar-alerts.nextappointment",
            "context": context,
            "payload": payload
        ])
    }
}

extension StreamDeckPlugin: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        send(["event": registerEvent, "uuid": uuid])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        NSLog("[CalendarAlerts] Stream Deck closed the connection (code \(closeCode.rawValue)) — exiting")
        exit(0)
    }
}
