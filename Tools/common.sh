# Shared by deploy.sh and package.sh. Source this file; don't run it.

PLUGIN_ID="com.joeangell.calendar-alerts"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="${ROOT}/StreamDeck Calendar Alerts.xcodeproj"
BUILD_DIR="${ROOT}/.build"
BUILD_LOG="${BUILD_DIR}/build.log"
EXEC="${BUILD_DIR}/Build/Products/Release/StreamDeck Calendar Alerts"
ENTITLEMENTS="${ROOT}/StreamDeck Calendar Alerts/StreamDeck Calendar Alerts.entitlements"
HELPER_ENTITLEMENTS="${ROOT}/StreamDeck Calendar Alerts/CalendarHelper.entitlements"
INSTALLED_PLUGIN_DIR="${HOME}/Library/Application Support/com.elgato.StreamDeck/Plugins/${PLUGIN_ID}.sdPlugin"
VERSION="$(plutil -extract Version raw "${ROOT}/manifest.json")"

# xcodebuild needs full Xcode. If xcode-select points at the Command Line Tools,
# use /Applications/Xcode.app instead.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]] \
        && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "==> Using ${DEVELOPER_DIR} (xcode-select points at the Command Line Tools)"
fi

# Prints the first code-signing identity whose name contains $1, e.g. "Developer ID Application".
find_identity() {
    security find-identity -v -p codesigning | sed -n "s/.*\"\(${1}[^\"]*\)\".*/\1/p" | head -1
}

# build_plugin <signing identity> <output dir> <timestamp flag>
# Builds Release and assembles <output dir>/<PLUGIN_ID>.sdPlugin, signed with the
# given identity. Pass --timestamp for release builds, --timestamp=none otherwise.
build_plugin() {
    local sign_id="$1" out_dir="$2" timestamp="$3"
    local bundle="${out_dir}/${PLUGIN_ID}.sdPlugin"
    local helper="${bundle}/CalendarHelper.app"

    echo "==> Building Release ${VERSION}..."
    mkdir -p "${BUILD_DIR}"
    rm -f "${EXEC}"   # so a failed build can't leave an old binary behind
    # Xcode's own signing is off (the project names Joe's team, which other people
    # don't have); everything is signed below with the identity passed in.
    if ! xcodebuild \
            -project "${PROJECT_FILE}" \
            -scheme "StreamDeck Calendar Alerts" \
            -configuration Release \
            -derivedDataPath "${BUILD_DIR}" \
            CODE_SIGNING_ALLOWED=NO \
            build > "${BUILD_LOG}" 2>&1; then
        grep -E "error:" "${BUILD_LOG}" || tail -20 "${BUILD_LOG}"
        echo "BUILD FAILED (full log: ${BUILD_LOG})"
        exit 1
    fi
    grep -E "warning:" "${BUILD_LOG}" | sort -u || true
    if [ ! -f "${EXEC}" ]; then
        echo "ERROR: Build output not found at ${EXEC}"
        exit 1
    fi
    echo "** BUILD SUCCEEDED **"

    echo "==> Assembling ${bundle}..."
    rm -rf "${bundle}"
    mkdir -p "${bundle}/Images" "${bundle}/propertyinspector"
    cp "${EXEC}" "${bundle}/StreamDeck Calendar Alerts"
    cp "${ROOT}/manifest.json" "${bundle}/"
    cp "${ROOT}/Images/"*.png "${bundle}/Images/"
    cp "${ROOT}/propertyinspector/"* "${bundle}/propertyinspector/"

    # CalendarHelper.app: the same executable, run as its own app so macOS asks
    # for (and remembers) calendar access for it rather than for Stream Deck.
    # LSUIElement keeps it out of the Dock; it only shows itself while asking.
    mkdir -p "${helper}/Contents/MacOS"
    cp "${EXEC}" "${helper}/Contents/MacOS/CalendarHelper"
    cat > "${helper}/Contents/Info.plist" <<HPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${PLUGIN_ID}</string>
    <key>CFBundleName</key>
    <string>StreamDeck Calendar Alerts</string>
    <key>CFBundleExecutable</key>
    <string>CalendarHelper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Calendar Alerts needs access to show your upcoming appointments on the StreamDeck.</string>
</dict>
</plist>
HPLIST
    xattr -cr "${bundle}"

    # Sign with hardened runtime (required for notarization) and the calendar
    # entitlement it needs for EventKit.
    echo "==> Signing with ${sign_id}..."
    codesign --force --sign "${sign_id}" --entitlements "${ENTITLEMENTS}" \
        --options runtime "${timestamp}" "${bundle}/StreamDeck Calendar Alerts"
    codesign --force --sign "${sign_id}" --entitlements "${HELPER_ENTITLEMENTS}" \
        --options runtime "${timestamp}" "${helper}"
    codesign --verify --strict "${bundle}/StreamDeck Calendar Alerts"
    codesign --verify --strict "${helper}"
    echo "Signatures OK"
}

# Quits Stream Deck (which stops the plugin) and any CalendarHelper still running.
# Replacing a running signed binary can get it killed, and a helper left running
# would keep using the old code.
stop_stream_deck() {
    echo "==> Stopping Stream Deck and CalendarHelper..."
    if pgrep -x "Stream Deck" >/dev/null; then
        killall "Stream Deck" 2>/dev/null || true
        for _ in {1..20}; do
            pgrep -x "Stream Deck" >/dev/null || break
            sleep 0.5
        done
    fi
    pkill -f "${PLUGIN_ID}.sdPlugin/CalendarHelper.app/Contents/MacOS/CalendarHelper" 2>/dev/null || true
}
