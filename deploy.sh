#!/bin/bash
# Builds the plugin and installs it straight into this Mac's Stream Deck app.
# For day-to-day development; use package.sh to make an installer to share.
#
#   ./deploy.sh                 signs with your first "Apple Development" identity
#   SIGN_ID="..." ./deploy.sh   signs with a specific identity
set -euo pipefail
source "$(dirname "$0")/Tools/common.sh"

SIGN_ID="${SIGN_ID:-$(find_identity "Apple Development")}"
if [ -z "${SIGN_ID}" ]; then
    echo "ERROR: No Apple Development signing identity found. Add your Apple ID in"
    echo "Xcode → Settings → Accounts, or set SIGN_ID to another identity."
    exit 1
fi

STAGE="${BUILD_DIR}/stage"
build_plugin "${SIGN_ID}" "${STAGE}" --timestamp=none

stop_stream_deck

echo "==> Installing into ${INSTALLED_PLUGIN_DIR}..."
mkdir -p "${INSTALLED_PLUGIN_DIR}"
rsync -a --delete "${STAGE}/${PLUGIN_ID}.sdPlugin/" "${INSTALLED_PLUGIN_DIR}/"

echo "==> Starting Stream Deck..."
open "/Applications/Elgato Stream Deck.app"
echo "Done."
