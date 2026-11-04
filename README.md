# Calendar Alerts for Stream Deck

<img src="Images/pluginIcon@2x.png" width="128" align="right" alt="Calendar Alerts icon">

A Stream Deck plugin for macOS that puts your next calendar event on a key. It counts down to the event with color-coded urgency, plays an alert sound as the event gets close, and flashes **NOW** in the final minute. Press the key to open your calendar app.

<p>
<img src="docs/images/key-90m.png" width="72" alt="1h 30m">
<img src="docs/images/key-45m.png" width="72" alt="45 minutes">
<img src="docs/images/key-25m.png" width="72" alt="25 minutes">
<img src="docs/images/key-12m.png" width="72" alt="12 minutes">
<img src="docs/images/key-8m.png" width="72" alt="8 minutes">
<img src="docs/images/key-3m.png" width="72" alt="3 minutes">
<img src="docs/images/key-now.png" width="72" alt="NOW">
<img src="docs/images/no-events-smile.png" width="72" alt="No more events">
</p>

**[Download the installer](https://github.com/jangellx/StreamDeck-Calendar-Alerts/releases/latest/download/com.joeangell.calendar-alerts.streamDeckPlugin)**. Requires macOS 14 or later and the Stream Deck app.

## What it shows

The key shows the title of your next event today and how long until it starts:

| Time until the event | Key |
|---|---|
| 60 minutes or more | Hours and minutes, no color (`1h 30m`) |
| 31–59 minutes | Light blue |
| 16–30 minutes | Blue |
| 11–15 minutes | Yellow |
| 6–10 minutes | Orange |
| 1–5 minutes | Red |
| Final minute | Flashing red **NOW** |

- Your Mac's alert sound plays at 60, 30, 15 and 5 minutes before each event.
- Only events still to come today are shown. All-day events, cancelled events and events you've declined are skipped.
- A leading room number is trimmed from titles, so "101 Team Standup" shows as "Team Standup".
- When there's nothing left today, the key shows a smiling calendar, or whichever image you've picked (see below).

## Settings

Select the key in the Stream Deck app to see its settings. Each key has its own, so you can have one key for work calendars and another for family.

- **Show events from**: check the calendars to include. All of them are included until you uncheck one.
- **When pressed, open**: Apple Calendar, any other calendar app you have installed (such as Fantastical, BusyCal or Outlook), or a web page or URL (such as `calendar.google.com`).
- **When there are no more events**: choose what the key shows.

  <img src="docs/images/no-events-smile.png" width="56" alt="Smiling calendar (light)"> <img src="docs/images/no-events-smile-dark.png" width="56" alt="Smiling calendar (dark)"> <img src="docs/images/no-events-check.png" width="56" alt="Checkmark"> <img src="docs/images/no-events-text.png" width="56" alt="Text only">

  The choices are a smiling calendar (light or dark), a checkmark, a thumbs-up 👍, or just the words "No more events". You can also use your own image: choose **Your own image…**, then drag an image file onto the settings panel or click **choose a file**. It's scaled to fit the key.

## Install

### With the installer

1. Download **[com.joeangell.calendar-alerts.streamDeckPlugin](https://github.com/jangellx/StreamDeck-Calendar-Alerts/releases/latest/download/com.joeangell.calendar-alerts.streamDeckPlugin)** from the [latest release](https://github.com/jangellx/StreamDeck-Calendar-Alerts/releases/latest).
2. Double-click it. The Stream Deck app opens and asks to install the plugin.
3. In the Stream Deck app's action list, find the **Calendar Alerts** group and drag **Next Appointment** onto a key.
4. When macOS asks whether "StreamDeck Calendar Alerts" can access your calendars, click **Allow**.

To update, download and double-click the newer installer the same way.

### Without the installer

**Copy it in by hand.** The `.streamDeckPlugin` file is a zip archive.

1. Download it, change its extension to `.zip`, and double-click it to unzip.
2. Quit the Stream Deck app.
3. Move the `com.joeangell.calendar-alerts.sdPlugin` folder into `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`, replacing any older copy.
4. Open the Stream Deck app again, then carry on from step 3 above.

**Build it from source.** You need macOS 14 or later, Xcode 16 or later, and a code-signing identity. Signing into Xcode with any Apple ID (Xcode → Settings → Accounts) gives you a free "Apple Development" identity.

```bash
git clone https://github.com/jangellx/StreamDeck-Calendar-Alerts.git
cd StreamDeck-Calendar-Alerts
./deploy.sh
```

`deploy.sh` builds the plugin, signs it with your first Apple Development identity (set `SIGN_ID` to use another), quits Stream Deck, installs the plugin into Stream Deck's Plugins folder, and starts Stream Deck again. Run it again after each change.

### Making the installer

`./package.sh` builds `dist/com.joeangell.calendar-alerts.streamDeckPlugin`, signed with a Developer ID certificate and notarized by Apple so it opens on any Mac. It needs a paid Apple Developer Program membership and this one-time setup:

1. In Xcode → Settings → Accounts → Manage Certificates, click **+** and add a **Developer ID Application** certificate.
2. Save notarization credentials (this prompts for an [app-specific password](https://support.apple.com/102654)):
   ```bash
   xcrun notarytool store-credentials CalendarAlerts --apple-id <your Apple ID> --team-id <your team ID>
   ```

Then attach the file to a GitHub release. The download links above always point at the newest release, as long as the file keeps that name. `./package.sh --skip-notarize` builds an un-notarized copy for testing on your own Mac.

## How it works

The plugin has three parts:

- **The plugin program** (`StreamDeck Calendar Alerts`): a Swift command-line program that Stream Deck starts. It talks to the Stream Deck app over its local WebSocket. Once a minute it draws each key's image, plays alert sounds, and opens your chosen app when a key is pressed.
- **CalendarHelper.app**: the same program, run as a small background app. macOS ties calendar permission to the app that asks for it, and a plugin started by Stream Deck would be asking on Stream Deck's behalf. So the plugin starts this helper, which asks for calendar access under its own name ("StreamDeck Calendar Alerts") and reads today's events with EventKit. It saves the events and the calendar list to `~/Library/Caches/com.joeangell.calendar-alerts/`, both when a calendar changes and every 30 seconds, and the plugin reads them from there. The helper quits when the plugin does.
- **The settings panel** (`propertyinspector/index.html`): the web page Stream Deck shows when you select the key. It saves each key's settings in Stream Deck.

```
Stream Deck app ⇄ WebSocket ⇄ plugin program ──starts──▶ CalendarHelper.app ⇄ EventKit
                                     ▲                           │
                                     └── reads ── ~/Library/Caches/com.joeangell.calendar-alerts/ ◀── writes
```

### Project layout

| Path | What it is |
|---|---|
| `StreamDeck Calendar Alerts/` | Swift sources for the plugin program and helper |
| `propertyinspector/` | The settings panel |
| `Images/` | Icons and key images (made by `Tools/make-images.sh`) |
| `manifest.json` | Stream Deck's description of the plugin |
| `deploy.sh` | Build and install on this Mac |
| `package.sh` | Build the signed, notarized installer |
| `Tools/` | Shared build steps and the image generator |

## Troubleshooting

- **The key says "No calendar access".** Open System Settings → Privacy & Security → Calendars and turn on **StreamDeck Calendar Alerts**. The key updates within a minute.
- **To be asked for calendar access again**, reset the permission and restart Stream Deck:
  ```bash
  tccutil reset Calendar com.joeangell.calendar-alerts
  ```
- **Stream Deck's own log** is at `~/Library/Logs/ElgatoStreamDeck/StreamDeck.log`. Search it for `calendar-alerts`.

To uninstall, quit Stream Deck and delete `~/Library/Application Support/com.elgato.StreamDeck/Plugins/com.joeangell.calendar-alerts.sdPlugin` and `~/Library/Caches/com.joeangell.calendar-alerts`.

## Credits

- The idea, and the colors for each stage of the countdown, come from TJ Luoma's [icalbuddy-km-and-stream-deck](https://github.com/tjluoma/icalbuddy-km-and-stream-deck). It uses icalBuddy and Keyboard Maestro to show the time until your next meeting on a Stream Deck key.
- I had trouble with the shell scripts, so I switched to Shortcuts before writing this plugin. That idea came from ringmaster's [iCal Daily Schedule via iOS/OSX Shortcut](https://forum.obsidian.md/t/ical-daily-schedule-via-ios-osx-shortcut/30686) on the Obsidian forum.
- The plugin icon and the smiling calendar are from my app Perpetual. The other images are drawn in code.
