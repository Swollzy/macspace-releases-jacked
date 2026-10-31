#!/bin/bash
# Double-click once on the Mac that makes the DMGs. After this, every "Make DMG.command"
# (Wallflower, Burrow, Swivel, Molt) signs the app with your Developer ID and has Apple
# notarize it, so it opens on friends' Macs with no "Open Anyway" step.
#
# It sets up, skipping whatever is already done:
#   1. A "Developer ID Application" certificate. If the keychain has none, it makes the
#      request file, opens Apple's page for it, and installs the certificate you download.
#   2. Apple's notary login: your Apple ID and an app-specific password, kept in the keychain.
#   3. ~/Library/Application Support/Swollzy/signing.conf, naming the two (no passwords).
#
# Needs a paid Apple Developer Program membership (you, as the account holder).
# If macOS won't open this file: System Settings > Privacy & Security > Open Anyway.
#
# Keep this file plain ASCII and write variables as ${NAME}: macOS ships bash 3.2.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNING_SH="${HERE}/signing.sh"
[[ -f "${SIGNING_SH}" ]] || SIGNING_SH="${HERE}/dmg/signing.sh"
INLINE=0
[[ "${1:-}" == "--inline" ]] && INLINE=1

say() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m%s\033[0m\n' "$*"; }
finish() {
    echo
    if [[ "${INLINE}" == 0 && -t 0 ]]; then read -r -p "Press Return to close this window. " _ || true; fi
    exit "$1"
}
fail() { printf '  \033[31m%s\033[0m\n' "$*" >&2; finish 1; }

[[ "$(uname)" == "Darwin" ]] || { echo "This runs on a Mac."; finish 1; }
[[ -f "${SIGNING_SH}" ]] || fail "signing.sh is missing next to this file."
# shellcheck source=/dev/null
. "${SIGNING_SH}"

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
[[ -f "${KEYCHAIN}" ]] || KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
REQ_DIR="${SIGNING_DIR}/certificate-request"
DESKTOP_CSR="${HOME}/Desktop/Developer ID request.certSigningRequest"

printf '\n\033[1m%s\033[0m\n' "Set up Apple signing for your DMGs"

# Apple's free Command Line Tools have notarytool.
have_tools() { xcode-select -p >/dev/null 2>&1 && xcrun --find notarytool >/dev/null 2>&1; }
if ! have_tools; then
    say "This needs Apple's free Command Line Tools (one time, about 5 minutes)."
    say "A window will pop up: click Install. This waits and carries on by itself."
    xcode-select --install >/dev/null 2>&1 || true
    for _ in $(seq 1 360); do
        have_tools && break
        sleep 5
    done
    have_tools || fail "The Command Line Tools still aren't installed. Install them, then run this again."
fi

# --- 1. The Developer ID certificate ---------------------------------------------------

# Developer ID certificates are issued by these two Apple intermediates; without them in the
# keychain the certificate shows as "not trusted" and can't sign. Adding them twice is harmless.
add_apple_intermediates() {
    local tmp ca
    tmp="$(mktemp -d)"
    for ca in DeveloperIDG2CA DeveloperIDCA; do
        if curl -fsSL "https://www.apple.com/certificateauthority/${ca}.cer" -o "${tmp}/${ca}.cer"; then
            security import "${tmp}/${ca}.cer" -k "${KEYCHAIN}" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "${tmp}"
}

# Puts a downloaded .cer together with the key made for its request into the keychain.
install_certificate() { # path to the .cer -> 0 if it went in
    local cer="$1" tmp pass
    tmp="$(mktemp -d)"
    chmod 700 "${tmp}"
    if ! openssl x509 -inform DER -in "${cer}" -out "${tmp}/cert.pem" 2>/dev/null \
        && ! openssl x509 -in "${cer}" -out "${tmp}/cert.pem" 2>/dev/null; then
        warn "$(basename "${cer}") isn't a certificate file."; rm -rf "${tmp}"; return 1
    fi
    if ! openssl x509 -noout -subject -in "${tmp}/cert.pem" | grep -q "Developer ID Application"; then
        warn "$(basename "${cer}") isn't a Developer ID Application certificate (pick that type on Apple's page)."
        rm -rf "${tmp}"; return 1
    fi
    if [[ "$(openssl x509 -noout -modulus -in "${tmp}/cert.pem")" != "$(openssl rsa -noout -modulus -in "${REQ_DIR}/key.pem" 2>/dev/null)" ]]; then
        warn "$(basename "${cer}") was made from a different request file, not the one this made."
        warn "On Apple's page, upload \"$(basename "${DESKTOP_CSR}")\" from your Desktop."
        rm -rf "${tmp}"; return 1
    fi
    pass="$(openssl rand -hex 16)"
    # macOS reads only the older .p12 encryption; -legacy asks OpenSSL 3 for it (LibreSSL does it anyway).
    openssl pkcs12 -export -legacy -inkey "${REQ_DIR}/key.pem" -in "${tmp}/cert.pem" -name "Developer ID Application" \
            -out "${tmp}/id.p12" -passout "pass:${pass}" 2>/dev/null \
        || openssl pkcs12 -export -inkey "${REQ_DIR}/key.pem" -in "${tmp}/cert.pem" -name "Developer ID Application" \
            -out "${tmp}/id.p12" -passout "pass:${pass}" \
        || { warn "Couldn't package the certificate."; rm -rf "${tmp}"; return 1; }
    add_apple_intermediates
    if ! security import "${tmp}/id.p12" -k "${KEYCHAIN}" -P "${pass}" -T /usr/bin/codesign -T /usr/bin/security >/dev/null; then
        warn "The keychain didn't take the certificate."; rm -rf "${tmp}"; return 1
    fi
    rm -rf "${tmp}"
    return 0
}

step "1 of 3  Developer ID certificate"
IDS="$(signing_identities)"
if [[ -z "${IDS}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    # It's there but not trusted: the intermediate certificate is missing.
    add_apple_intermediates
    IDS="$(signing_identities)"
fi
if [[ -z "${IDS}" ]]; then
    mkdir -p "${REQ_DIR}"
    chmod 700 "${SIGNING_DIR}" "${REQ_DIR}"
    # The key stays on this Mac. It's reused if this runs again, so a certificate made from
    # an earlier run's request still fits.
    if [[ ! -f "${REQ_DIR}/key.pem" ]]; then
        openssl genrsa -out "${REQ_DIR}/key.pem" 2048 2>/dev/null || fail "Couldn't make a key."
        chmod 600 "${REQ_DIR}/key.pem"
    fi
    openssl req -new -key "${REQ_DIR}/key.pem" -subj "/CN=Developer ID request/" \
        -out "${DESKTOP_CSR}" 2>/dev/null || fail "Couldn't make the request file."
    MARK="${REQ_DIR}/started"
    touch "${MARK}"
    say "Your browser opens Apple's certificate page. Sign in if asked, then:"
    say "  a. Pick \"Developer ID Application\" and click Continue."
    say "  b. Leave \"G2 Sub-CA\" picked. Click Choose File and pick"
    say "     \"$(basename "${DESKTOP_CSR}")\" on your Desktop. Click Continue."
    say "  c. Click Download."
    say "This window notices the download and carries on by itself. If macOS asks whether"
    say "Terminal may use your Downloads folder, click Allow."
    say "(If the download went somewhere else, drag the .cer file into this window and press Return.)"
    open "https://developer.apple.com/account/resources/certificates/add" 2>/dev/null || true
    for _ in $(seq 1 600); do
        IDS="$(signing_identities)"
        [[ -n "${IDS}" ]] && break                 # made another way, e.g. in Xcode
        CER=""
        if read -r -t 3 TYPED 2>/dev/null; then
            TYPED="${TYPED%\"}"; TYPED="${TYPED#\"}"; TYPED="${TYPED%\'}"; TYPED="${TYPED#\'}"
            TYPED="${TYPED%% }"; TYPED="${TYPED//\\ / }"
            [[ -f "${TYPED}" ]] && CER="${TYPED}"
        else
            CER="$(find "${HOME}/Downloads" -maxdepth 1 -type f -name '*.cer' -newer "${MARK}" 2>/dev/null | head -1)"
        fi
        if [[ -n "${CER}" ]]; then
            sleep 1
            if install_certificate "${CER}"; then
                IDS="$(signing_identities)"
                [[ -n "${IDS}" ]] && break
                warn "The certificate went in, but macOS doesn't trust it yet."
            fi
            touch "${MARK}"                         # wait for a different file
        fi
    done
    [[ -n "${IDS}" ]] || fail "No Developer ID certificate yet. Run this again when you have it."
    rm -f "${DESKTOP_CSR}" "${MARK}"
    rm -f "${REQ_DIR}/key.pem"                      # the keychain has the key now
    rmdir "${REQ_DIR}" 2>/dev/null || true
fi

# One Developer ID is the usual case. With several, the newest-looking first one is used;
# put its name in signing.conf to choose another.
SIGN_HASH="$(printf '%s\n' "${IDS}" | sed -n 1p | cut -f1)"
SIGN_NAME="$(printf '%s\n' "${IDS}" | sed -n 1p | cut -f2-)"
TEAM_ID="$(printf '%s' "${SIGN_NAME}" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
[[ -n "${TEAM_ID}" ]] || fail "Couldn't read the Team ID from \"${SIGN_NAME}\"."
say "Using ${SIGN_NAME}"

# A test signature now, so macOS asks for keychain access here and not halfway through a build.
say "Testing it. If macOS asks to let codesign use your key, type your Mac login password"
say "and click Always Allow."
TEST="$(mktemp -d)"
cp /usr/bin/true "${TEST}/signing-test"
if ! codesign --force --options runtime --timestamp --sign "${SIGN_HASH}" "${TEST}/signing-test" 2> "${TEST}/err"; then
    cat "${TEST}/err" >&2
    rm -rf "${TEST}"
    fail "The test signature failed. Check you're online and clicked Always Allow, then run this again."
fi
rm -rf "${TEST}"
say "Signing works."

# --- 2. Notary login -------------------------------------------------------------------
step "2 of 3  Apple notary login"
profile_works() { xcrun notarytool history --keychain-profile "$1" >/dev/null 2>&1; }
PROFILE=""
for p in "${SIGNING_PROFILE}" Molt; do
    if profile_works "${p}"; then PROFILE="${p}"; break; fi
done
if [[ -n "${PROFILE}" ]]; then
    say "Already saved in the keychain."
else
    say "Apple checks each DMG for malware before friends open it (a few minutes per DMG)."
    say "That needs an app-specific password, which is made once:"
    say "  a. Your browser opens account.apple.com. Sign in."
    say "  b. Sign-In and Security > App-Specific Passwords > + . Name it \"notary\"."
    say "  c. Copy the password it shows (like abcd-efgh-ijkl-mnop)."
    open "https://account.apple.com/account/manage" 2>/dev/null || true
    for try in 1 2 3; do
        echo
        read -r -p "  Your Apple ID email: " APPLE_ID || fail "No Apple ID given."
        APPLE_ID="$(printf '%s' "${APPLE_ID}" | tr -d '[:space:]')"
        [[ -n "${APPLE_ID}" ]] || continue
        say "Now paste the app-specific password and press Return (it stays hidden as you type)."
        if xcrun notarytool store-credentials "${SIGNING_PROFILE}" --apple-id "${APPLE_ID}" --team-id "${TEAM_ID}"; then
            PROFILE="${SIGNING_PROFILE}"
            break
        fi
        warn "Apple didn't accept that (try ${try} of 3). Check the email and paste the password again."
        warn "If it mentions an agreement: sign in at developer.apple.com/account and accept it first."
    done
    [[ -n "${PROFILE}" ]] || fail "The notary login isn't saved. Run this again to retry."
    say "Saved in the keychain."
fi

# --- 3. Remember them ------------------------------------------------------------------
step "3 of 3  Saving the settings"
mkdir -p "${SIGNING_DIR}"
{
    echo "# Written by Set Up Signing.command on $(date '+%Y-%m-%d'). No passwords here: those are in the keychain."
    echo "DEVELOPER_ID=${SIGN_NAME}"
    echo "TEAM_ID=${TEAM_ID}"
    echo "NOTARY_PROFILE=${PROFILE}"
} > "${SIGNING_CONF}"
say "Saved ${SIGNING_CONF/#${HOME}/~}"

echo
printf '  \033[32m%s\033[0m\n' "All set. Every Make DMG.command now signs and notarizes by itself."
say "Friends just drag the app to Applications and open it."
finish 0
