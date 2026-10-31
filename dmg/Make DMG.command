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
# Apple signing: once "Set Up Signing.command" has run, DMGs open on friends' Macs with no
# warning. Until then, offer it (it skips what's already done, so a no costs nothing later).
SIGNING_CONF="${HOME}/Library/Application Support/Swollzy/signing.conf"
if [[ ! -f "${SIGNING_CONF}" && -z "${DEVELOPER_ID:-}" && -t 0 ]]; then
    echo
    echo "Apple signing isn't set up on this Mac yet, so friends would have to click 'Open Anyway'."
    read -r -p "Set it up now? It's once, about 5 minutes, and needs your Apple Developer account. [Y/n] " ANSWER || ANSWER="n"
    case "${ANSWER}" in
        [nN]*) echo "Making an unsigned DMG. Double-click Set Up Signing.command any time to add signing." ;;
        *) bash "${HERE}/Set Up Signing.command" --inline || echo "Signing isn't set up, so this DMG is unsigned." ;;
    esac
fi

mkdir -p "${OUT}"
printf '\n\033[1m%s\033[0m\n' "Molt"
if ! bash "${HERE}/make-dmg.sh" "${OUT}"; then
    echo
    if [[ -f "${OUT}/Molt-notarize.log" ]]; then
        echo "  Apple didn't notarize Molt. Run this again, or send Molt-notarize.log from ${OUT} to Claude."
    else
        echo "  Molt didn't build. Send Molt-build-error.log from ${OUT} to Claude."
    fi
    open "${OUT}"
    finish 1
fi
open "${OUT}"
echo
echo "  Send friends the .dmg file."
finish 0
