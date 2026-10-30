#!/bin/bash
# Builds Molt from this checkout and wraps it in a drag-to-Applications DMG.
#
#   bash dmg/make-dmg.sh <output-folder>
#
# Molt needs Xcode 27 or later (the macOS 27 SDK; the Command Line Tools alone lack SwiftUI's macros). It is built for macOS 26
# and later as one universal app for Apple silicon and Intel. If that build fails, it is built again for macOS 27 on Apple silicon
# only, and the first build's errors are kept in Molt-build-error.log. Signed with your Developer ID or Apple Development
# certificate when the keychain has one, ad-hoc otherwise (friends then use "Open Anyway" once).
#
#   MOLT_VERSION=1.0.1 bash dmg/make-dmg.sh ~/Desktop/DMGs     another version number
#
# Keep this file plain ASCII and write variables as ${NAME}: macOS ships bash 3.2.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
OUT_ARG="${1:?usage: make-dmg.sh <output-folder>}"
mkdir -p "${OUT_ARG}"
OUT="$(cd "${OUT_ARG}" && pwd)"
VERSION="${MOLT_VERSION:-1.0.0}"
LOG="${OUT}/Molt-build-error.log"

info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }
die() { printf '    \033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "DMGs are made on a Mac."
rm -f "${LOG}"

# --- 1. Find Xcode 27 or later ---------------------------------------------------------
XCODE=""
BEST=""
for app in /Applications/Xcode*.app; do
    [[ -d "${app}/Contents/Developer" ]] || continue
    v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist" 2>/dev/null || true)"
    case "${v}" in [0-9]*) ;; *) continue ;; esac
    [[ "${v%%.*}" -ge 27 ]] || continue
    if [[ -z "${BEST}" ]] || [[ "$(printf '%s\n%s\n' "${BEST}" "${v}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "${v}" ]]; then
        BEST="${v}"; XCODE="${app}"
    fi
done
if [[ -z "${XCODE}" ]]; then
    warn "Molt needs Xcode 27 or later, free from the App Store. Opening its page."
    warn "Install it, open it once so it finishes setting up, then run this again."
    open "macappstore://apps.apple.com/app/xcode/id497799835" 2>/dev/null || true
    exit 1
fi
export DEVELOPER_DIR="${XCODE}/Contents/Developer"
info "Using Xcode ${BEST}"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    info "Xcode has to finish setting up once. Type your Mac password if asked."
    sudo "${DEVELOPER_DIR}/usr/bin/xcodebuild" -runFirstLaunch || die "Xcode didn't finish setting up. Open Xcode once, then run this again."
fi

# --- 2. Build --------------------------------------------------------------------------
cd "${ROOT}" || die "Can't open ${ROOT}"
build() { # minimum macOS -> 0 if it built
    MOLT_MIN_MACOS="$1" VERSION="${VERSION}" DEV=0 NOTARY_PROFILE="" bash Scripts/Assemble.sh > "${OUT}/.molt-build-$1.log" 2>&1
}
MIN="26.0"
info "Building Molt ${VERSION} for macOS 26 and later, Apple silicon and Intel (a few minutes)"
if ! build 26.0; then
    { echo "macOS $(sw_vers -productVersion) $(uname -m), Xcode ${BEST}, building for macOS 26"; echo
      tail -n 200 "${OUT}/.molt-build-26.0.log"; } > "${LOG}"
    grep -m 10 "error:" "${OUT}/.molt-build-26.0.log" >&2 || true
    warn "That build failed. Building again for macOS 27 on Apple silicon only."
    MIN="27.0"
    if ! build 27.0; then
        { echo; echo "macOS $(sw_vers -productVersion), building for macOS 27"; echo
          tail -n 200 "${OUT}/.molt-build-27.0.log"; } >> "${LOG}"
        grep -m 10 "error:" "${OUT}/.molt-build-27.0.log" >&2 || true
        rm -f "${OUT}"/.molt-build-*.log
        die "Molt didn't build. Details are in ${LOG}"
    fi
fi
rm -f "${OUT}"/.molt-build-*.log
APP="${ROOT}/Build/Molt.app"
[[ -d "${APP}" ]] || die "The build finished but ${APP} is missing."
codesign --verify --deep --strict "${APP}" || die "Molt's signature didn't verify."
SIGNER="$(codesign -dvv "${APP}" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -n "${SIGNER}" ]]; then info "Signed by ${SIGNER}"; else warn "Signed ad-hoc: the helper (Debloat, model freeing) won't run from this DMG."; fi

# --- 3. The DMG ------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/Molt"
mkdir -p "${STAGE}"
ditto "${APP}" "${STAGE}/Molt.app"
ln -s /Applications "${STAGE}/Applications"
if [[ "${MIN}" == "26.0" ]]; then NEEDS="macOS 26 or later, on any Mac (Apple silicon or Intel)"; else NEEDS="macOS 27 or later, on an Apple silicon Mac"; fi
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{NEEDS}}/${NEEDS}/g" "${HERE}/Read Me First.txt" > "${STAGE}/Read Me First.txt"
DMG="${OUT}/Molt-${VERSION}.dmg"
rm -f "${DMG}"
hdiutil create -quiet -volname "Molt ${VERSION}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${DMG}" || die "hdiutil create failed."
(cd "${OUT}" && shasum -a 256 "$(basename "${DMG}")" > "$(basename "${DMG}").sha256")
info "Made ${DMG} (${NEEDS})"
[[ -f "${LOG}" ]] && warn "The macOS 26 build failed, so this DMG needs macOS 27; send ${LOG} to Claude to fix it."
exit 0
