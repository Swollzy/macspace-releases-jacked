#!/bin/bash
# Builds Molt from this checkout and wraps it in a drag-to-Applications DMG.
#
#   bash dmg/make-dmg.sh <output-folder>
#
# Molt needs Xcode 27 or later (the macOS 27 SDK; the Command Line Tools alone lack SwiftUI's macros). It is built for macOS 26
# and later as one universal app for Apple silicon and Intel. If that build fails, it is built again for macOS 27 on Apple silicon
# only, and the first build's errors are kept in Molt-build-error.log.
#
# Once "Set Up Signing.command" (next to this file, which Make DMG offers) has stored a "Developer ID Application" certificate and
# Apple's notary login, the app and the DMG are signed with it and notarized by Apple, so they open on any Mac with no warning and
# the helper works. Without it the app is signed with what the keychain has, or ad-hoc (friends then use "Open Anyway" once, and
# the helper doesn't run).
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
# "Set Up Signing.command" (next to this file, shared with Swollzy's other apps) stores the
# certificate's name and the notary login once; signing.sh reads them.
# shellcheck source=signing.sh
. "${HERE}/signing.sh"
DEVID=""
TEAM=""
NOTARIZE=""
if signing_load; then
    DEVID="${SIGN_NAME}"
    TEAM="${TEAM_ID}"
    info "Signing with ${DEVID}"
    if [[ -n "${NOTARY_PROFILE}" ]]; then
        NOTARIZE="${NOTARY_PROFILE}"
    elif xcrun notarytool history --keychain-profile Molt >/dev/null 2>&1; then
        NOTARIZE="Molt"   # saved by an earlier version of this script
    else
        warn "No notary login saved, so Apple won't notarize this DMG. Double-click dmg/Set Up Signing.command to add it."
    fi
else
    warn "No Developer ID certificate set up, so this DMG won't be notarized and the helper won't run."
    warn "Double-click dmg/Set Up Signing.command once, then run this again."
fi
NOTARY_LOG="${OUT}/Molt-notarize.log"
rm -f "${NOTARY_LOG}"

# --- 3. Update key ---------------------------------------------------------------------
# A notarized Molt updates itself (Sparkle): every update is signed with a private key that stays in this Mac's keychain, and the
# app carries the public half, so it installs nothing else. The key is made the first time; it has to stay the same for good, as
# every copy already out there checks updates against it.
cd "${ROOT}" || die "Can't open ${ROOT}"
SPARKLE_ACCOUNT="molt"
UPDATE_KEY=""
SPARKLE_BIN=""
REPO_URL="https://github.com/Swollzy/macspace-releases-jacked"
if [[ -n "${NOTARIZE}" ]]; then
    swift package resolve >/dev/null 2>&1 || true
    SPARKLE_BIN="$(dirname "$(find "${ROOT}/.build/artifacts" -type f -name generate_keys -perm -u+x 2>/dev/null | head -1)")"
    if [[ -x "${SPARKLE_BIN}/generate_keys" && -x "${SPARKLE_BIN}/sign_update" ]]; then
        if ! UPDATE_KEY="$("${SPARKLE_BIN}/generate_keys" --account "${SPARKLE_ACCOUNT}" -p 2>/dev/null)" || [[ -z "${UPDATE_KEY}" ]]; then
            info "Making Molt's update key (once). It is kept in your keychain; click Always Allow if macOS asks."
            "${SPARKLE_BIN}/generate_keys" --account "${SPARKLE_ACCOUNT}" >/dev/null 2>&1 || true
            UPDATE_KEY="$("${SPARKLE_BIN}/generate_keys" --account "${SPARKLE_ACCOUNT}" -p 2>/dev/null || true)"
            if [[ -n "${UPDATE_KEY}" ]]; then
                BACKUP="${HOME}/Desktop/Molt-update-key-BACKUP.txt"
                "${SPARKLE_BIN}/generate_keys" --account "${SPARKLE_ACCOUNT}" -x "${BACKUP}" >/dev/null 2>&1 \
                    && warn "Saved a backup of the update key to ${BACKUP}. Keep it somewhere safe and private (a password manager), then delete it."
            fi
        fi
        [[ -n "${UPDATE_KEY}" ]] && info "Updates on: this Molt checks for new versions and installs only ones you signed"
    fi
    [[ -n "${UPDATE_KEY}" ]] || warn "Couldn't set up the update key, so this Molt won't update itself."
fi

# --- 4. Build --------------------------------------------------------------------------
build() { # minimum macOS -> 0 if it built
    if [[ -n "${DEVID}" ]]; then
        MOLT_MIN_MACOS="$1" VERSION="${VERSION}" DEV=0 SIGN_IDENTITY="${DEVID}" TEAM_ID="${TEAM}" NOTARY_PROFILE="${NOTARIZE}" \
            SPARKLE_PUBLIC_KEY="${UPDATE_KEY}" FEED_URL="${UPDATE_KEY:+${REPO_URL}/releases/latest/download/appcast.xml}" \
            bash Scripts/Assemble.sh > "${OUT}/.molt-build-$1.log" 2>&1
    else
        MOLT_MIN_MACOS="$1" VERSION="${VERSION}" DEV=0 NOTARY_PROFILE="" bash Scripts/Assemble.sh > "${OUT}/.molt-build-$1.log" 2>&1
    fi
}
MIN="26.0"
info "Building Molt ${VERSION} for macOS 26 and later, Apple silicon and Intel (a few minutes${NOTARIZE:+, plus the Apple check})"
if ! build 26.0; then
    # Built, but Apple turned the app down: building again for macOS 27 wouldn't help.
    if grep -qE "error: (notarization|could not submit)" "${OUT}/.molt-build-26.0.log"; then
        tail -n 100 "${OUT}/.molt-build-26.0.log" > "${NOTARY_LOG}"
        rm -f "${OUT}"/.molt-build-*.log
        die "Apple didn't notarize Molt. The reason is in ${NOTARY_LOG}"
    fi
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

# --- 5. The DMG ------------------------------------------------------------------------
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
    | signing_readme_filter "${KIND}" > "${STAGE}/Read Me First.txt"
DMG="${OUT}/Molt-${VERSION}.dmg"
rm -f "${DMG}"
hdiutil create -quiet -volname "Molt ${VERSION}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${DMG}" || die "hdiutil create failed."
if [[ -n "${NOTARIZE}" ]]; then
    # The DMG is signed and notarized too, so a friend's Mac checks it before it is even opened.
    codesign --force --timestamp --sign "${SIGN_HASH}" "${DMG}" || die "Couldn't sign the DMG."
    info "Apple is checking the DMG (usually a few minutes)"
    NOTARY_PROFILE="${NOTARIZE}"
    if ! signing_notarize "${DMG}" "${NOTARY_LOG}"; then
        # Not shared by mistake: its read-me says it opens with no warning.
        rm -f "${DMG}"
        die "Apple didn't accept the DMG. The reason is in ${NOTARY_LOG}"
    fi
    spctl -a -t open --context context:primary-signature "${DMG}" 2>/dev/null && info "Notarized: opens on any Mac with no warning"
fi
(cd "${OUT}" && shasum -a 256 "$(basename "${DMG}")" > "$(basename "${DMG}").sha256")
info "Made ${DMG} (${NEEDS})"

# --- 6. The update feed ----------------------------------------------------------------
# appcast.xml tells copies already installed about this version. Put it and the DMG on a GitHub release named v<version>: the app
# reads the feed of the latest release, then checks the DMG's signature against its key before installing.
if [[ -n "${UPDATE_KEY}" && -n "${NOTARIZE}" ]]; then
    SIG="$("${SPARKLE_BIN}/sign_update" --account "${SPARKLE_ACCOUNT}" "${DMG}" 2>/dev/null || true)"
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist")"
    if [[ "${SIG}" == *edSignature=* ]]; then
        cat > "${OUT}/appcast.xml" <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Molt</title>
    <item>
      <title>Molt ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN}</sparkle:minimumSystemVersion>
      <link>${REPO_URL}/releases/tag/v${VERSION}</link>
      <enclosure url="${REPO_URL}/releases/download/v${VERSION}/Molt-${VERSION}.dmg" type="application/octet-stream" ${SIG} />
    </item>
  </channel>
</rss>
FEED
        info "Made ${OUT}/appcast.xml. To ship this version as an update, put it and the DMG on a release named v${VERSION}:"
        info "  ${REPO_URL}/releases/new?tag=v${VERSION}"
    else
        warn "Couldn't sign the update, so no appcast.xml this time. The DMG itself is fine."
    fi
fi
[[ -f "${LOG}" ]] && warn "The macOS 26 build failed, so this DMG needs macOS 27; send ${LOG} to Claude to fix it."
exit 0
