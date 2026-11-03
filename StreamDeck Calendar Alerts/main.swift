import Foundation
import AppKit
import EventKit

// StreamDeck launches the plugin executable with these arguments:
//   -port <port> -pluginUUID <uuid> -registerEvent registerPlugin -info <json>
//
// CalendarHelper.app (inside the plugin bundle) is launched by the plugin via
// NSWorkspace with --calendar-service. It reads calendar events and writes them
// to shared temp files which the plugin reads. This lets it have its own TCC
// context independent of StreamDeck's process hierarchy.

let launchedByStreamDeck = CommandLine.arguments.contains("-port")
let calendarServiceMode  = CommandLine.arguments.contains("--calendar-service")

if calendarServiceMode {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let runner = CalendarServiceRunner()
    runner.start()
    app.run()
    exit(0)
}

if !launchedByStreamDeck {
    // Legacy permission-helper mode: launched from Finder (no -port, no --calendar-service).
    // Requests TCC access and quits. Kept for manual debugging.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let store = EKEventStore()
    DispatchQueue.main.async {
        store.requestFullAccessToEvents { granted, error in
            let msg = "Calendar access: granted=\(granted) error=\(String(describing: error))"
            print(msg)
            try? msg.write(toFile: "/tmp/calendar-auth-helper-result.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    app.run()
    exit(0)
}

var port = 0
var pluginUUID = ""
var registerEvent = "registerPlugin"

var idx = 1
let args = CommandLine.arguments
while idx < args.count {
    switch args[idx] {
    case "-port" where idx + 1 < args.count:
        port = Int(args[idx + 1]) ?? 0
        idx += 2
    case "-pluginUUID" where idx + 1 < args.count:
        pluginUUID = args[idx + 1]
        idx += 2
    case "-registerEvent" where idx + 1 < args.count:
        registerEvent = args[idx + 1]
        idx += 2
    default:
        idx += 1
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Launch CalendarHelper.app (which lives in the same directory as this binary)
// via NSWorkspace so it runs as its own LaunchServices process with its own
// TCC context. It will read calendar events and write shared temp files.
let myDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let helperURL = myDir.appendingPathComponent("CalendarHelper.app")
if FileManager.default.fileExists(atPath: helperURL.path) {
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = ["--calendar-service"]
    config.activates = false
    NSWorkspace.shared.openApplication(at: helperURL, configuration: config) { _, error in
        if let error = error {
            NSLog("[CalendarAlerts] Failed to launch CalendarHelper: \(error)")
        } else {
            NSLog("[CalendarAlerts] CalendarHelper.app launched")
        }
    }
} else {
    NSLog("[CalendarAlerts] CalendarHelper.app not found at \(helperURL.path)")
}

let plugin = StreamDeckPlugin(port: port, uuid: pluginUUID, registerEvent: registerEvent)
plugin.connect()

app.run()
