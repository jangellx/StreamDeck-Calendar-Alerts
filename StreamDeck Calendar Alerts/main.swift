import Foundation
import AppKit
import EventKit

// StreamDeck launches the plugin executable with these arguments:
//   -port <port> -pluginUUID <uuid> -registerEvent registerPlugin -info <json>
//
// CalendarHelper.app (inside the plugin bundle) is launched by the plugin via
// NSWorkspace with --calendar-service. It reads calendar events and writes them
// to shared files (see CalendarManager) which the plugin reads. This lets it have
// its own TCC context independent of StreamDeck's process hierarchy.

let launchedByStreamDeck = CommandLine.arguments.contains("-port")
let calendarServiceMode  = CommandLine.arguments.contains("--calendar-service")

if calendarServiceMode {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let runner = CalendarServiceRunner()
    let helperArgs = CommandLine.arguments
    if let i = helperArgs.firstIndex(of: "--parent-pid"), i + 1 < helperArgs.count,
       let pid = pid_t(helperArgs[i + 1]) {
        runner.watchParent(pid: pid)
    }
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
// TCC context. It will read calendar events and write the shared files.
let myDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let helperURL = myDir.appendingPathComponent("CalendarHelper.app")
let myPID = ProcessInfo.processInfo.processIdentifier

// Stop helpers left over from an earlier plugin run: they may be running old code,
// and LaunchServices would otherwise reuse one instead of starting a fresh copy.
for stale in NSRunningApplication.runningApplications(withBundleIdentifier: "com.joeangell.calendar-alerts")
    where stale.processIdentifier != myPID && stale.bundleURL?.lastPathComponent == "CalendarHelper.app" {
    NSLog("[CalendarAlerts] Stopping leftover CalendarHelper (pid \(stale.processIdentifier))")
    stale.forceTerminate()
}

if FileManager.default.fileExists(atPath: helperURL.path) {
    let config = NSWorkspace.OpenConfiguration()
    // --parent-pid lets the helper exit when this plugin process does.
    config.arguments = ["--calendar-service", "--parent-pid", String(myPID)]
    config.activates = false
    config.createsNewApplicationInstance = true
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
