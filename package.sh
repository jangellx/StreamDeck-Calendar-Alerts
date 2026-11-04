#!/bin/bash
# Builds the installer people download: dist/com.joeangell.calendar-alerts.streamDeckPlugin
# Double-clicking it makes Stream Deck install (or update) the plugin.
#
# Release builds are signed with a Developer ID Application certificate and
# notarized by Apple, so Gatekeeper lets them run on any Mac. One-time setup:
#   1. Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. xcrun notarytool store-credentials CalendarAlerts --apple-id <you> --team-id <TEAMID>
#
#   ./package.sh                  signed with Developer ID and notarized
#   ./package.sh --skip-notarize  signed with SIGN_ID (or Apple Development), not
#                                 notarized: for testing the installer locally only
#
# Environment: SIGN_ID (signing identity), NOTARY_PROFILE (default "CalendarAlerts").
set -euo pipefail
source "$(dirname "$0")/Tools/common.sh"

NOTARIZE=1
if [ "${1:-}" = "--skip-notarize" ]; then NOTARIZE=0; fi
NOTARY_PROFILE="${NOTARY_PROFILE:-CalendarAlerts}"

if [ "${NOTARIZE}" = 1 ]; then
    SIGN_ID="${SIGN_ID:-$(find_identity "Developer ID Application")}"
    if [ -z "${SIGN_ID}" ]; then
        echo "ERROR: No \"Developer ID Application\" signing identity in your keychain."
        echo "Create one in Xcode → Settings → Accounts → Manage Certificates (+),"
        echo "or run ./package.sh --skip-notarize to build an un-notarized test copy."
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        echo "ERROR: No notarytool credentials saved as \"${NOTARY_PROFILE}\". Save them with:"
        echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <your Apple ID> --team-id <team ID>"
        exit 1
    fi
else
    SIGN_ID="${SIGN_ID:-$(find_identity "Apple Development")}"
fi

WORK="${BUILD_DIR}/package"
DIST="${ROOT}/dist"
OUTPUT="${DIST}/${PLUGIN_ID}.streamDeckPlugin"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${DIST}"

build_plugin "${SIGN_ID}" "${WORK}" --timestamp

# A .streamDeckPlugin is a zip with the .sdPlugin folder at its root.
zip_plugin() {
    rm -f "$1"
    (cd "${WORK}" && ditto -c -k --norsrc --noextattr --noqtn --keepParent "${PLUGIN_ID}.sdPlugin" "$1")
}

if [ "${NOTARIZE}" = 1 ]; then
    echo "==> Submitting to Apple's notary service (this can take a few minutes)..."
    zip_plugin "${WORK}/notarize.zip"
    RESULT="$(xcrun notarytool submit "${WORK}/notarize.zip" --keychain-profile "${NOTARY_PROFILE}" \
        --wait --output-format json)"
    STATUS="$(plutil -extract status raw -o - - <<< "${RESULT}")"
    SUBMISSION="$(plutil -extract id raw -o - - <<< "${RESULT}")"
    echo "Notarization: ${STATUS} (submission ${SUBMISSION})"
    if [ "${STATUS}" != "Accepted" ]; then
        xcrun notarytool log "${SUBMISSION}" --keychain-profile "${NOTARY_PROFILE}" || true
        exit 1
    fi

    # Attach the ticket to the helper app so Gatekeeper can check it offline.
    # (The plugin executable isn't a bundle; Gatekeeper looks its ticket up online.)
    xcrun stapler staple "${WORK}/${PLUGIN_ID}.sdPlugin/CalendarHelper.app"
    spctl --assess --type execute -vv "${WORK}/${PLUGIN_ID}.sdPlugin/CalendarHelper.app"
fi

zip_plugin "${OUTPUT}"
echo ""
echo "✓ ${OUTPUT}"
if [ "${NOTARIZE}" = 0 ]; then
    echo "  (not notarized: other Macs will block it)"
fi
