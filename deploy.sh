#!/bin/bash
set -e

PLUGIN_ID="com.joeangell.calendar-alerts"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="${PROJECT_DIR}/StreamDeck Calendar Alerts.xcodeproj"
BUILD_DIR="${PROJECT_DIR}/.build"
PLUGIN_DIR="${HOME}/Library/Application Support/com.elgato.StreamDeck/Plugins/${PLUGIN_ID}.sdPlugin"
ENTITLEMENTS="${PROJECT_DIR}/StreamDeck Calendar Alerts/StreamDeck Calendar Alerts.entitlements"
HELPER_ENTITLEMENTS="${PROJECT_DIR}/StreamDeck Calendar Alerts/CalendarHelper.entitlements"
SIGN_ID="Apple Development: Joe Angell (AZDX94UY8R)"

echo "==> Building Release..."
xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "StreamDeck Calendar Alerts" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

EXEC="${BUILD_DIR}/Build/Products/Release/StreamDeck Calendar Alerts"
if [ ! -f "${EXEC}" ]; then
    echo "ERROR: Build output not found at ${EXEC}"
    exit 1
fi

echo "==> Creating plugin bundle..."
mkdir -p "${PLUGIN_DIR}/Images"

echo "==> Copying executable, manifest, and images..."
cp "${EXEC}" "${PLUGIN_DIR}/StreamDeck Calendar Alerts"
chmod +x "${PLUGIN_DIR}/StreamDeck Calendar Alerts"

# Re-sign without get-task-allow=true (Xcode injects it during dev signing; it
# causes SIGKILL on Apple Silicon when the process runs outside the debugger).
echo "==> Re-signing plugin binary (removing get-task-allow)..."
codesign --force --sign "${SIGN_ID}" \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    "${PLUGIN_DIR}/StreamDeck Calendar Alerts"

cp "${PROJECT_DIR}/manifest.json" "${PLUGIN_DIR}/"
if [ -d "${PROJECT_DIR}/Images" ]; then
    cp "${PROJECT_DIR}/Images/"* "${PLUGIN_DIR}/Images/" 2>/dev/null || true
fi
if [ -d "${PROJECT_DIR}/propertyinspector" ]; then
    mkdir -p "${PLUGIN_DIR}/propertyinspector"
    cp "${PROJECT_DIR}/propertyinspector/"* "${PLUGIN_DIR}/propertyinspector/"
fi

echo "==> Generating placeholder icons..."
python3 - "${PLUGIN_DIR}/Images" <<'PYEOF'
import sys, struct, zlib

def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

def make_png(size, rgb):
    header = b'\x89PNG\r\n\x1a\n'
    ihdr   = chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
    raw    = (b'\x00' + bytes(rgb) * size) * size
    idat   = chunk(b'IDAT', zlib.compress(raw, 9))
    iend   = chunk(b'IEND', b'')
    return header + ihdr + idat + iend

out_dir = sys.argv[1]
color = [18, 18, 30]
for name in ['pluginIcon.png', 'action.png', 'pluginIcon@2x.png', 'action@2x.png']:
    size = 144 if '@2x' in name else 72
    with open(f'{out_dir}/{name}', 'wb') as f:
        f.write(make_png(size, color))
PYEOF

# Build CalendarHelper.app inside the plugin directory.
# The plugin binary launches this via NSWorkspace so it runs as its own
# LaunchServices process with its own TCC context. It reads calendar events
# (using the com.joeangell.calendar-alerts TCC permission already granted)
# and writes them to /tmp for the plugin to read.
echo "==> Creating CalendarHelper.app..."
HELPER_APP="${PLUGIN_DIR}/CalendarHelper.app"
rm -rf "${HELPER_APP}"
mkdir -p "${HELPER_APP}/Contents/MacOS"

cat > "${HELPER_APP}/Contents/Info.plist" <<HPLIST
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
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Calendar Alerts needs access to show your upcoming appointments on the StreamDeck.</string>
</dict>
</plist>
HPLIST

cp "${EXEC}" "${HELPER_APP}/Contents/MacOS/CalendarHelper"
xattr -cr "${HELPER_APP}"
codesign --force --deep --sign "${SIGN_ID}" \
    --entitlements "${HELPER_ENTITLEMENTS}" \
    --options runtime \
    "${HELPER_APP}"

codesign --verify --deep --strict "${HELPER_APP}" 2>&1 && echo "CalendarHelper.app signature: OK" || echo "WARNING: CalendarHelper.app signature invalid"

echo ""
echo "✓ Installed: ${PLUGIN_DIR}"
echo ""

echo "==> Restarting StreamDeck..."
killall "Stream Deck" 2>/dev/null || true
sleep 1
open "/Applications/Elgato Stream Deck.app"
echo "Done."
