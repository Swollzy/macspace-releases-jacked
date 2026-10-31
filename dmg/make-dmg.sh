#!/bin/bash
# Builds Molt from this checkout and wraps it in a drag-to-Applications DMG.
#
#   bash dmg/make-dmg.sh <output-folder>
#
# Molt needs Xcode 27 or later (the macOS 27 SDK; the Command Line Tools alone lack SwiftUI's macros). It is built for macOS 26
# and later as one universal app for Apple silicon and Intel. If that build fails, it is built again for macOS 27 on Apple silicon
# only, and the first build's errors are kept in Molt-build-error.log.
#
# With a "Developer ID Application" certificate in the keychain (a paid Apple developer account), the app and the DMG are signed
# with it and notarized by Apple, so they open on any Mac with no warning and the helper works. The first run asks once for the
# Apple ID and an app-specific password and keeps them in the keychain as the notarytool profile "Molt". Without the certificate
# it signs with what the keychain has, or ad-hoc (friends then use "Open Anyway" once, and the helper doesn't run).
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

# --- 2. Developer ID and notarization -------------------------------------------------
PROFILE="Molt"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^ *[0-9]+\) [0-9A-F]+ "(Developer ID Application:.*)"$/\1/p' | head -1)"
NOTARIZE=""
if [[ -z "${DEVID}" ]]; then
    warn "No Developer ID Application certificate in your keychain, so this DMG won't be notarized and the helper won't run."
    warn "To make one: Xcode > Settings > Accounts, pick your team, Manage Certificates, + > Developer ID Application."
    warn "Then run this again."
else
    TEAM="$(printf '%s' "${DEVID}" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
    info "Signing with ${DEVID}"
    if ! xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
        info "Apple has to notarize Molt. This is asked once and saved in your keychain."
        info "Make an app-specific password at account.apple.com > Sign-In and Security > App-Specific Passwords (opening it now)."
        open "https://account.apple.com/account/manage" 2>/dev/null || true
        printf '    Apple ID email: '
        read -r APPLE_ID
        [[ -n "${APPLE_ID}" ]] || die "No Apple ID given."
        info "Now paste the app-specific password (it doesn't show as you type)."
        xcrun notarytool store-credentials "${PROFILE}" --apple-id "${APPLE_ID}" --team-id "${TEAM}" \
            || die "Apple didn't accept that Apple ID and password. Run this again to retry."
    fi
    NOTARIZE="${PROFILE}"
fi

# --- 3. Build --------------------------------------------------------------------------
cd "${ROOT}" || die "Can't open ${ROOT}"
build() { # minimum macOS -> 0 if it built
    if [[ -n "${DEVID}" ]]; then
        MOLT_MIN_MACOS="$1" VERSION="${VERSION}" DEV=0 SIGN_IDENTITY="${DEVID}" NOTARY_PROFILE="${NOTARIZE}" \
            bash Scripts/Assemble.sh > "${OUT}/.molt-build-$1.log" 2>&1
    else
        MOLT_MIN_MACOS="$1" VERSION="${VERSION}" DEV=0 NOTARY_PROFILE="" bash Scripts/Assemble.sh > "${OUT}/.molt-build-$1.log" 2>&1
    fi
}
MIN="26.0"
info "Building Molt ${VERSION} for macOS 26 and later, Apple silicon and Intel (a few minutes${NOTARIZE:+, plus the Apple check})"
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

# --- 4. The DMG ------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/Molt"
mkdir -p "${STAGE}"
ditto "${APP}" "${STAGE}/Molt.app"
ln -s /Applications "${STAGE}/Applications"
if [[ "${MIN}" == "26.0" ]]; then NEEDS="macOS 26 or later, on any Mac (Apple silicon or Intel)"; else NEEDS="macOS 27 or later, on an Apple silicon Mac"; fi
# The read-me keeps the [signed] or the [unsigned] parts, whichever this DMG is.
if [[ -n "${NOTARIZE}" ]]; then KIND="signed"; else KIND="unsigned"; fi
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{NEEDS}}/${NEEDS}/g" "${HERE}/Read Me First.txt" \
    | awk -v kind="${KIND}" '/^\[(signed|unsigned)\]$/ { part = substr($0, 2, length($0) - 2); next }
                              /^\[\/\]$/ { part = ""; next }
                              part == "" || part == kind' > "${STAGE}/Read Me First.txt"
DMG="${OUT}/Molt-${VERSION}.dmg"
rm -f "${DMG}"
hdiutil create -quiet -volname "Molt ${VERSION}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${DMG}" || die "hdiutil create failed."
if [[ -n "${NOTARIZE}" ]]; then
    # The DMG is signed and notarized too, so a friend's Mac checks it before it is even opened.
    codesign --force --timestamp --sign "${DEVID}" "${DMG}" || die "Couldn't sign the DMG."
    info "Apple is checking the DMG (usually a few minutes)"
    xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait > "${WORK}/notary.txt" 2>&1
    if ! grep -q "status: Accepted" "${WORK}/notary.txt"; then
        cat "${WORK}/notary.txt" > "${LOG}"
        die "Apple didn't accept the DMG. Details are in ${LOG}"
    fi
    xcrun stapler staple "${DMG}" >/dev/null || die "Couldn't attach Apple's ticket to the DMG."
    spctl -a -t open --context context:primary-signature "${DMG}" 2>/dev/null && info "Notarized: opens on any Mac with no warning"
fi
(cd "${OUT}" && shasum -a 256 "$(basename "${DMG}")" > "$(basename "${DMG}").sha256")
info "Made ${DMG} (${NEEDS})"
[[ -f "${LOG}" ]] && warn "The macOS 26 build failed, so this DMG needs macOS 27; send ${LOG} to Claude to fix it."
exit 0
