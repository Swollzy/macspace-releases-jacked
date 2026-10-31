# Developer ID signing and Apple notarization for the DMG makers. make-dmg.sh sources this.
#
# The same file is in the Wallflower, Burrow, Swivel and Molt repos (dmg/signing.sh): change
# all four together.
#
# "Set Up Signing.command" stores everything once on the Mac that makes the DMGs:
#   - the "Developer ID Application" certificate and its key, in the login keychain
#   - the notary login (Apple ID + app-specific password), in the keychain as a notarytool profile
#   - ~/Library/Application Support/Swollzy/signing.conf, which names the two (no passwords)
#
# DEVELOPER_ID and NOTARY_PROFILE in the environment win over the file. DEVELOPER_ID=- makes
# an ad-hoc build, NOTARY_PROFILE= (empty) a signed one that isn't notarized.
#
# Keep this file plain ASCII and write variables as ${NAME}: macOS ships bash 3.2.

SIGNING_DIR="${HOME}/Library/Application Support/Swollzy"
SIGNING_CONF="${SIGNING_DIR}/signing.conf"
SIGNING_PROFILE="Swollzy"

# One "HASH<tab>NAME" line per usable Developer ID Application identity in the keychains.
signing_identities() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/^ *[0-9]+\) ([0-9A-Fa-f]{40}) "(Developer ID Application: .*)"$/\1	\2/p'
}

signing_conf_get() { # key -> its value in signing.conf, or nothing
    [[ -f "${SIGNING_CONF}" ]] || return 0
    sed -n "s/^$1=//p" "${SIGNING_CONF}" | tail -1
}

# Sets SIGN_NAME (the certificate's name), SIGN_HASH (its SHA-1: codesign is given the hash,
# because a renewed certificate with the same name makes signing by name "ambiguous"),
# TEAM_ID and NOTARY_PROFILE. Returns 0 when there is a Developer ID to sign with.
signing_load() {
    SIGN_NAME=""
    SIGN_HASH=""
    TEAM_ID=""
    if [[ -n "${NOTARY_PROFILE+x}" ]]; then :; else NOTARY_PROFILE="$(signing_conf_get NOTARY_PROFILE)"; fi
    local want="${DEVELOPER_ID:-}"
    [[ -n "${want}" ]] || want="$(signing_conf_get DEVELOPER_ID)"
    if [[ "${want}" == "-" ]]; then NOTARY_PROFILE=""; return 1; fi
    local ids line
    ids="$(signing_identities)"
    if [[ -n "${want}" ]]; then
        line="$(printf '%s\n' "${ids}" | awk -F '\t' -v w="${want}" '$2 == w || toupper($1) == toupper(w) { print; exit }')"
        if [[ -z "${line}" ]]; then
            printf '    \033[33m%s\033[0m\n' "\"${want}\" isn't in this Mac's keychain (expired, or set up on another Mac)." >&2
            printf '    \033[33m%s\033[0m\n' "Double-click Set Up Signing.command to fix it. Making an unsigned DMG for now." >&2
            NOTARY_PROFILE=""
            return 1
        fi
    else
        line="$(printf '%s\n' "${ids}" | sed -n 1p)"
    fi
    if [[ -z "${line}" ]]; then NOTARY_PROFILE=""; return 1; fi
    SIGN_HASH="${line%%	*}"
    SIGN_NAME="${line#*	}"
    TEAM_ID="$(printf '%s' "${SIGN_NAME}" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
    return 0
}

# Signs every Mach-O file inside the bundle first (codesign wants inside-out), then the bundle,
# with the hardened runtime and a secure timestamp, as notarization requires.
#   signing_sign_app <app> <bundle-id> [entitlements.plist]
signing_sign_app() {
    local app="$1" id="$2" ent="${3:-}" main f
    local flags=(--force --options runtime --timestamp --sign "${SIGN_HASH}")
    main="${app}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Contents/Info.plist" 2>/dev/null)"
    while IFS= read -r f; do
        [[ "${f}" == "${main}" ]] && continue
        if file -b "${f}" 2>/dev/null | grep -q '^Mach-O'; then
            codesign "${flags[@]}" "${f}" || return 1
        fi
    done < <(find "${app}/Contents" -type f -perm -u+x)
    if [[ -n "${ent}" ]]; then
        codesign "${flags[@]}" --identifier "${id}" --entitlements "${ent}" "${app}" || return 1
    else
        codesign "${flags[@]}" --identifier "${id}" "${app}" || return 1
    fi
    codesign --verify --strict --deep "${app}"
}

# Has Apple notarize a signed DMG (or zip), then staples the ticket to it so it also opens
# offline. On failure Apple's reasons go into <log> and it returns 1.
#   signing_notarize <file> <log>
signing_notarize() {
    local file="$1" log="$2" out err status id
    out="$(mktemp)"
    err="$(mktemp)"
    xcrun notarytool submit "${file}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json > "${out}" 2> "${err}"
    status="$(plutil -extract status raw -o - "${out}" 2>/dev/null || true)"
    id="$(plutil -extract id raw -o - "${out}" 2>/dev/null || true)"
    if [[ "${status}" != "Accepted" ]]; then
        {
            echo "Notarizing $(basename "${file}") on $(date): status ${status:-none}"
            echo
            cat "${out}" "${err}"
            if [[ -n "${id}" ]]; then
                echo
                echo "Apple's report:"
                xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" 2>&1
            fi
        } > "${log}"
        if grep -qiE '401|unauthori[sz]ed|credentials|keychain profile|No Keychain password item' "${err}"; then
            echo "Apple didn't accept the saved notary login. Double-click Set Up Signing.command to enter it again." >> "${log}"
        elif grep -qiE '403|agreement' "${err}"; then
            echo "Apple wants an agreement accepted: sign in at developer.apple.com/account and accept it, then try again." >> "${log}"
        fi
        rm -f "${out}" "${err}"
        return 1
    fi
    rm -f "${out}" "${err}"
    # Right after "Accepted" Apple's ticket can take a moment to show up (error 65, "Record not
    # found"), so stapling gets a few tries before the DMG counts as failed.
    echo "Stapling $(basename "${file}") on $(date): Apple accepted it (submission ${id})" > "${log}"
    local try
    for try in 1 2 3 4; do
        if xcrun stapler staple "${file}" >> "${log}" 2>&1; then
            rm -f "${log}"
            return 0
        fi
        [[ "${try}" == 4 ]] || sleep 15
    done
    echo "Apple notarized it, but its ticket couldn't be attached. Run Make DMG again in a few minutes." >> "${log}"
    return 1
}

# Keeps the [signed] or the [unsigned] parts of a read-me, whichever this DMG is. A part
# starts with a line [signed] or [unsigned] and ends with a line [/].
#   signing_readme_filter signed|unsigned < in > out
signing_readme_filter() {
    awk -v kind="$1" '/^\[(signed|unsigned)\]$/ { part = substr($0, 2, length($0) - 2); next }
                      /^\[\/\]$/ { part = ""; next }
                      part == "" || part == kind'
}
