#!/bin/bash
# Double-click this on your Mac to build Molt and wrap it in a DMG that friends can install
# by dragging to Applications. The DMG lands in a "DMGs" folder on your Desktop.
#
# If macOS says it can't open this file: System Settings > Privacy & Security, scroll down,
# click "Open Anyway". Or in Terminal type "bash " and drag this file in.
#
# Keep this file plain ASCII and write variables as ${NAME}: macOS ships bash 3.2.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HOME}/Desktop/DMGs"

finish() {
    echo
    if [[ -t 0 ]]; then read -r -p "Press Return to close this window. " _ || true; fi
    exit "$1"
}

[[ "$(uname)" == "Darwin" ]] || { echo "This runs on a Mac."; finish 1; }
mkdir -p "${OUT}"
printf '\n\033[1m%s\033[0m\n' "Molt"
if ! bash "${HERE}/make-dmg.sh" "${OUT}"; then
    echo
    echo "  Molt didn't build. Send Molt-build-error.log from ${OUT} to Claude."
    open "${OUT}"
    finish 1
fi
open "${OUT}"
echo
echo "  Send friends the .dmg file. It has a 'Read Me First' with the one-time"
echo "  'Open Anyway' step macOS asks for on apps that aren't from the App Store."
finish 0
