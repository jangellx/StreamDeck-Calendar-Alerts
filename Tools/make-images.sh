#!/bin/bash
# Regenerates the plugin's images. The results are committed, so this only needs
# running when the artwork changes.
#
#   Images/pluginIcon, key, no-events-* exported from the ClockLoop and Bandit app
#                                       icons in Joe Angell's Perpetual project
#                                       (skipped if that project isn't next to this one;
#                                       set PERPETUAL_ICONS to its Icons folder)
#   Images/moon-00…29                   the moon-phase images Perpetual uses, from
#                                       NASA's Scientific Visualization Studio
#                                       (Dial-A-Moon), which NASA asks to be credited
#   Images/action, category             drawn by Tools/ImageTool
#   docs/images/*.png                   sample keys for the README
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

PERPETUAL_ICONS="${PERPETUAL_ICONS:-${ROOT}/../Perpetual/Perpetual/Icons}"
ICTOOL="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/../Applications/Icon Composer.app/Contents/Executables/ictool"

# export_icon <Perpetual icon name> <output name> <size in points> <Default|Dark>:
# writes name.png and name@2x.png using the light (Default) or Dark appearance
export_icon() {
    local scale suffix
    for scale in 1 2; do
        suffix=""; [ "${scale}" = 2 ] && suffix="@2x"
        "${ICTOOL}" "${PERPETUAL_ICONS}/$1.icon" --export-image \
            --output-file "${ROOT}/Images/$2${suffix}.png" \
            --platform macOS --rendition "$4" --width "$3" --height "$3" --scale "${scale}" >/dev/null
    done
}

mkdir -p "${ROOT}/Images"
if [ -d "${PERPETUAL_ICONS}" ] && [ -x "${ICTOOL}" ]; then
    echo "==> Exporting Perpetual icons from ${PERPETUAL_ICONS}"
    export_icon ClockLoop pluginIcon 256 Default   # plugin icon: 256 px, 512 px @2x
    export_icon ClockLoop key 72 Default           # default key image: 72 px, 144 px @2x
    export_icon Bandit no-events-light 72 Default  # "no more events" key images,
    export_icon Bandit no-events-dark 72 Dark      #   light and dark choices
else
    echo "==> Skipping Perpetual icons (not found at ${PERPETUAL_ICONS}, or Icon Composer missing)"
fi

# All thirty moon phases (moon-00 = new, moon-15 = full), at key size. The
# plugin shows today's (see MoonPhase.swift). Each photo is on black and fills the key.
MOONS="${PERPETUAL_ICONS}/../Assets.xcassets/Moon"
if [ -d "${MOONS}" ]; then
    echo "==> Exporting the moon phases"
    for i in $(seq -w 0 29); do
        sips -s format png -z 144 144 "${MOONS}/moon-${i}.imageset/moon-${i}.jpg" \
            --out "${ROOT}/Images/moon-${i}@2x.png" >/dev/null
    done
else
    echo "==> Skipping the moon phases (not found at ${MOONS})"
fi

echo "==> Drawing action and category icons, and README samples"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
xcrun swiftc -O -o "${TMP}/ImageTool" \
    "${ROOT}/StreamDeck Calendar Alerts/ButtonImageRenderer.swift" \
    "${ROOT}/StreamDeck Calendar Alerts/MoonPhase.swift" "${ROOT}/Tools/ImageTool/main.swift"
"${TMP}/ImageTool" "${ROOT}"
